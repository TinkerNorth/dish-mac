// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import CoreHaptics
import DishCore
import Foundation
import GameController
import os

/// About 10 % of the stick range and 5 % of the trigger range: a noise floor
/// that keeps a cheap pad from twitching at rest without clipping deliberate
/// small inputs.
let kDefaultStickFlat: Int16 = 3277
let kDefaultTriggerFlat: UInt8 = 13
/// MSG_BATTERY is a fixed 30 s cadence; the first sample waits for the
/// controller-add to settle.
let kBatteryPollIntervalSec = 30
let kBatteryFirstReportDelaySec = 1
/// `GCDeviceBattery` has no change notification, so a charging transition
/// is caught by this faster read-only poll.
let kBatteryStateWatchIntervalSec = 3

/// The XUSB bit each required button sets.
private let requiredButtons: [(KeyPath<GCExtendedGamepad, GCControllerButtonInput>, UInt16)] = [
    (\.buttonA, GamepadInputProcessor.Buttons.faceA),
    (\.buttonB, GamepadInputProcessor.Buttons.faceB),
    (\.buttonX, GamepadInputProcessor.Buttons.faceX),
    (\.buttonY, GamepadInputProcessor.Buttons.faceY),
    (\.leftShoulder, GamepadInputProcessor.Buttons.leftShoulder),
    (\.rightShoulder, GamepadInputProcessor.Buttons.rightShoulder),
    (\.buttonMenu, GamepadInputProcessor.Buttons.start),
    (\.dpad.up, GamepadInputProcessor.Buttons.dpadUp),
    (\.dpad.down, GamepadInputProcessor.Buttons.dpadDown),
    (\.dpad.left, GamepadInputProcessor.Buttons.dpadLeft),
    (\.dpad.right, GamepadInputProcessor.Buttons.dpadRight)
]

/// The XUSB bit each optional button sets when the pad has it.
private let optionalButtons: [(KeyPath<GCExtendedGamepad, GCControllerButtonInput?>, UInt16)] = [
    (\.buttonOptions, GamepadInputProcessor.Buttons.back),
    (\.leftThumbstickButton, GamepadInputProcessor.Buttons.leftThumb),
    (\.rightThumbstickButton, GamepadInputProcessor.Buttons.rightThumb)
]

/// Bridges GameController.framework into the input processor: one full
/// report per value change, plus the motion, touchpad and battery streams,
/// and the rumble and light-bar return paths.
@MainActor
final class GameControllerInput: ObservableObject {

    private static let log = Logger(subsystem: "com.tinkernorth.dish", category: "GC")

    /// One connected controller.
    struct Slot: Identifiable, Hashable {
        let id: String
        let name: String
        var capabilities: ControllerCapabilities = .none
        var battery: BatteryReading?
    }

    @Published var slots: [Slot] = []

    nonisolated let processor = GamepadInputProcessor()
    let touchpadIds = TouchpadTrackingState()

    private var observers: [NSObjectProtocol] = []
    private var controllerIds: [ObjectIdentifier: String] = [:]
    var controllersById: [String: GCController] = [:]
    var actuators: [String: RumbleActuator] = [:]
    var batteryTimers: [String: DispatchSourceTimer] = [:]
    var batteryStateTimers: [String: DispatchSourceTimer] = [:]
    var lastBatteryStatusRaw: [String: UInt8] = [:]

    /// The light-bar return path, serialised and coalesced per controller.
    lazy var lightbarApplier = ReturnPathApplier<LightbarColor>(label: "dish.returnpath.lightbar") { [weak self] deviceId, color in
        self?.writeLightbar(deviceId: deviceId, color: color)
    }

    /// The rumble return path, serialised and coalesced per controller.
    lazy var rumbleApplier = ReturnPathApplier<RumbleCommand>(label: "dish.returnpath.rumble") { [weak self] deviceId, command in
        self?.actuateRumble(deviceId: deviceId, command: command)
    }

    /// IOKit's battery snapshot is a blocking call, kept off the main thread.
    let batteryWorkQueue = DispatchQueue(label: "dish.battery.iokit", qos: .utility)

    struct LightbarColor {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    struct RumbleCommand {
        let strong: UInt16
        let weak: UInt16
        let durationMs: UInt16
    }

    /// A battery reading as the wire and the slot card each want it.
    struct BatteryResolution {
        let level: UInt8
        let statusRaw: UInt8
        let displayState: BatteryChargeState
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            Task { @MainActor in self.attach(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            Task { @MainActor in self.detach(controller) }
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Attach / detach

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let id = slotId(for: controller)
        let capabilities = Self.detectCapabilities(controller, pad: pad)
        recordSlot(id: id, controller: controller, capabilities: capabilities)
        processor.setDeadzones(deviceId: id, .init(stickFlat: kDefaultStickFlat, triggerFlat: kDefaultTriggerFlat))
        installReportHandler(id: id, pad: pad)
        installMotionHandler(id: id, controller: controller)
        installTouchpadHandlers(id: id, pad: pad)
        startBatteryTimer(deviceId: id, controller: controller)
    }

    /// The launch sweep and the connect notification can both fire for one
    /// pad; the same object keeps its id so a re-attach never reads as a
    /// second identical pad.
    private func slotId(for controller: GCController) -> String {
        let id = controllerIds[ObjectIdentifier(controller)] ?? stableId(for: controller)
        controllerIds[ObjectIdentifier(controller)] = id
        controllersById[id] = controller
        return id
    }

    /// `hasBattery` is always true: a pad without its own battery still
    /// reports the host Mac's.
    private static func detectCapabilities(_ controller: GCController, pad: GCExtendedGamepad) -> ControllerCapabilities {
        ControllerCapabilities(
            hasMotion: controller.motion != nil,
            hasTouchpad: touchpadInputs(pad) != nil,
            hasRumble: controller.haptics != nil,
            hasLightbar: controller.light != nil,
            hasBattery: true
        )
    }

    private func recordSlot(id: String, controller: GCController, capabilities: ControllerCapabilities) {
        let name = controller.vendorName ?? controller.productCategory
        if let index = slots.firstIndex(where: { $0.id == id }) {
            slots[index].capabilities = capabilities
        } else {
            slots.append(Slot(id: id, name: name, capabilities: capabilities))
        }
        Self.log.info("""
        DEVCAPS id=\(id, privacy: .public) name=\(name, privacy: .public) \
        category=\(controller.productCategory, privacy: .public) \
        extendedGamepad=yes motion=\(capabilities.hasMotion) touchpad=\(capabilities.hasTouchpad) \
        rumble=\(capabilities.hasRumble) lightbar=\(capabilities.hasLightbar) battery=\(capabilities.hasBattery)
        """)
    }

    /// GameController coalesces simultaneous changes into one call, and the
    /// handler rebuilds the whole report from the snapshot every time.
    private func installReportHandler(id: String, pad: GCExtendedGamepad) {
        pad.valueChangedHandler = { [weak self] pad, _ in
            self?.pushReport(id: id, pad: pad)
        }
    }

    private func detach(_ controller: GCController) {
        guard let id = controllerIds.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.motion?.valueChangedHandler = nil
        if let pad = controller.extendedGamepad, let touchpad = Self.touchpadInputs(pad) {
            touchpad.primary.valueChangedHandler = nil
            touchpad.secondary.valueChangedHandler = nil
            touchpad.button.valueChangedHandler = nil
        }
        slots.removeAll { $0.id == id }
        processor.remove(deviceId: id)
        controllersById.removeValue(forKey: id)
        actuators.removeValue(forKey: id)?.shutdown()
        batteryTimers.removeValue(forKey: id)?.cancel()
        batteryStateTimers.removeValue(forKey: id)?.cancel()
        lastBatteryStatusRaw.removeValue(forKey: id)
        touchpadIds.remove(deviceId: id)
    }

    /// Only the DualSense and DualShock 4 profiles expose a touchpad.
    static func touchpadInputs(_ pad: GCExtendedGamepad) -> TouchpadInputs? {
        if let dualSense = pad as? GCDualSenseGamepad {
            return TouchpadInputs(
                primary: dualSense.touchpadPrimary,
                secondary: dualSense.touchpadSecondary,
                button: dualSense.touchpadButton
            )
        }
        if let dualShock = pad as? GCDualShockGamepad {
            return TouchpadInputs(
                primary: dualShock.touchpadPrimary,
                secondary: dualShock.touchpadSecondary,
                button: dualShock.touchpadButton
            )
        }
        return nil
    }

    struct TouchpadInputs {
        let primary: GCControllerDirectionPad
        let secondary: GCControllerDirectionPad
        let button: GCControllerButtonInput
    }

    // MARK: - Hot path

    /// GameController's thumbstick y is up-positive; the wire's is
    /// down-positive, matching the other clients.
    private nonisolated func pushReport(id: String, pad: GCExtendedGamepad) {
        let report = GamepadReport(
            buttons: Self.buttonWord(pad),
            lt: scaleTrigger(pad.leftTrigger.value),
            rt: scaleTrigger(pad.rightTrigger.value),
            lx: scaleAxis(pad.leftThumbstick.xAxis.value, max: 32767),
            ly: scaleAxis(-pad.leftThumbstick.yAxis.value, max: 32767),
            rx: scaleAxis(pad.rightThumbstick.xAxis.value, max: 32767),
            ry: scaleAxis(-pad.rightThumbstick.yAxis.value, max: 32767)
        )
        processor.publish(deviceId: id, state: report)
    }

    nonisolated static func buttonWord(_ pad: GCExtendedGamepad) -> UInt16 {
        let required = requiredButtons.reduce(UInt16(0)) { word, entry in
            pad[keyPath: entry.0].isPressed ? word | entry.1 : word
        }
        let optional = optionalButtons.reduce(UInt16(0)) { word, entry in
            pad[keyPath: entry.0]?.isPressed == true ? word | entry.1 : word
        }
        return required | optional
    }

    // MARK: - Identity

    /// GameController vends a fresh object on every reconnect and exposes no
    /// per-unit identifier, so the id is the vendor name and product
    /// category, which survive a replug. Two identical pads get the lowest
    /// free ordinal.
    private func stableId(for controller: GCController) -> String {
        let vendor = controller.vendorName ?? "unknown"
        let base = "gc:\(vendor):\(controller.productCategory)"
        let attached = Set(controllerIds.values)
        if !attached.contains(base) { return base }
        var ordinal = 1
        while attached.contains("\(base)#\(ordinal)") {
            ordinal += 1
        }
        return "\(base)#\(ordinal)"
    }
}
