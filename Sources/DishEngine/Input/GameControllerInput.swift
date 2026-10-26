// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import CoreHaptics
import DishCore
import Foundation
import GameController
import os

/// MSG_BATTERY is a fixed 30 s cadence; the first sample waits for the
/// controller-add to settle.
let kBatteryPollIntervalSec = 30
let kBatteryFirstReportDelaySec = 1
/// `GCDeviceBattery` has no change notification, so a charging transition
/// is caught by this faster read-only poll.
let kBatteryStateWatchIntervalSec = 3

/// The wire button each required button is.
private let requiredButtons: [(KeyPath<GCExtendedGamepad, GCControllerButtonInput>, WireButton)] = [
    (\.buttonA, .faceA),
    (\.buttonB, .faceB),
    (\.buttonX, .faceX),
    (\.buttonY, .faceY),
    (\.leftShoulder, .leftShoulder),
    (\.rightShoulder, .rightShoulder),
    (\.buttonMenu, .start),
    (\.dpad.up, .dpadUp),
    (\.dpad.down, .dpadDown),
    (\.dpad.left, .dpadLeft),
    (\.dpad.right, .dpadRight)
]

/// The wire button each optional button is when the pad has it. XUSB has no
/// Share button and no paddles, so those stay unmapped.
private let optionalButtons: [(KeyPath<GCExtendedGamepad, GCControllerButtonInput?>, WireButton)] = [
    (\.buttonOptions, .back),
    (\.buttonHome, .guide),
    (\.leftThumbstickButton, .leftThumb),
    (\.rightThumbstickButton, .rightThumb)
]

/// Bridges GameController.framework into the input processor: one full
/// report per value change, plus the motion, touchpad and battery streams,
/// and the rumble and light-bar return paths.
@MainActor
final class GameControllerInput: ObservableObject {

    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "GC")

    /// One connected controller.
    struct Slot: Identifiable, Hashable {
        let id: String
        let name: String
        var capabilities: ControllerCapabilities = .none
        var battery: BatteryReading?
        /// The pad's family, which picks the catalog type it is emulated as.
        var family: PadFamily = .other
    }

    @Published var slots: [Slot] = []

    nonisolated let processor = GamepadInputProcessor()
    /// The one serial queue every controller's handlers run on, so the hot
    /// path never waits behind the main thread.
    nonisolated let inputQueue = DispatchQueue(label: "com.tinkernorth.dish.input", qos: .userInteractive)
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

    /// The adaptive-trigger return path, serialised and coalesced per controller.
    lazy var triggerEffectsApplier =
        ReturnPathApplier<TriggerEffectsCommand>(label: "dish.returnpath.triggers") { [weak self] deviceId, command in
            self?.writeTriggerEffects(deviceId: deviceId, command: command)
        }

    /// The player-LED return path, serialised and coalesced per controller.
    lazy var playerLedsApplier = ReturnPathApplier<Int>(label: "dish.returnpath.playerleds") { [weak self] deviceId, player in
        self?.writePlayerIndex(deviceId: deviceId, player: player)
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

    /// `connected` is the launch sweep, the framework's list unless a test
    /// hands in its own.
    init(connected: [GCController] = GCController.controllers()) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            Task { @MainActor in self.attach(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            Task { @MainActor in self.detach(controller) }
        })
        for controller in connected {
            attach(controller)
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Attach / detach

    /// The queue is the controller's before any handler is, so no event
    /// lands on the main queue first. Recording the slot is what hands the
    /// pad its dead zones (`observeDeadzones`), before its first report.
    private func attach(_ controller: GCController) {
        Self.monitorBackgroundEvents()
        if let pad = controller.extendedGamepad {
            attachExtended(controller, pad: pad)
        } else {
            attachByProfile(controller)
        }
    }

    /// A pad with the extended profile is read through its named inputs.
    private func attachExtended(_ controller: GCController, pad: GCExtendedGamepad) {
        let id = slotId(for: controller)
        let capabilities = Self.detectCapabilities(controller, pad: pad)
        recordSlot(id: id, controller: controller, capabilities: capabilities, family: Self.family(of: controller))
        controller.handlerQueue = inputQueue
        installReportHandler(id: id, pad: pad)
        installMotionHandler(id: id, controller: controller)
        installTouchpadHandlers(id: id, pad: pad)
        startBatteryTimer(deviceId: id, controller: controller)
    }

    /// Input keeps reaching Dish while another app is frontmost. Set at a
    /// connect, never before the first one: macOS 12.3.1 crashed when the
    /// flag was set ahead of it (SDL 09086ae).
    private static func monitorBackgroundEvents() {
        GCController.shouldMonitorBackgroundEvents = true
    }

    /// Whether the framework delivers input while Dish is in the background.
    nonisolated var monitorsBackgroundEvents: Bool {
        GCController.shouldMonitorBackgroundEvents
    }

    /// The launch sweep and the connect notification can both fire for one
    /// pad; the same object keeps its id so a re-attach never reads as a
    /// second identical pad.
    func slotId(for controller: GCController) -> String {
        let id = controllerIds[ObjectIdentifier(controller)] ?? stableId(for: controller)
        controllerIds[ObjectIdentifier(controller)] = id
        controllersById[id] = controller
        return id
    }

    /// `hasBattery` is always true: a pad without its own battery still
    /// reports the host Mac's. Only the DualSense takes trigger effects and
    /// has player LEDs the framework drives by player index.
    private static func detectCapabilities(_ controller: GCController, pad: GCExtendedGamepad) -> ControllerCapabilities {
        let dualSense = pad is GCDualSenseGamepad
        return ControllerCapabilities(
            hasMotion: controller.motion != nil,
            hasTouchpad: touchpadInputs(pad) != nil,
            hasRumble: controller.haptics != nil,
            hasLightbar: controller.light != nil,
            hasBattery: true,
            hasTriggerEffects: dualSense,
            hasPlayerLeds: dualSense
        )
    }

    /// The pad's family from the framework's product category; a category
    /// the framework exports no constant for is read by its words.
    static func family(of controller: GCController) -> PadFamily {
        switch controller.productCategory {
        case GCProductCategoryDualSense: .dualSense
        case GCProductCategoryDualShock4: .dualShock4
        case GCProductCategoryXboxOne: .xbox
        default: namedPadFamily(productCategory: controller.productCategory, vendorName: controller.vendorName)
        }
    }

    /// The DEVCAPS line names everything the framework says of the pad, so
    /// a pad nobody here has held can be read from a log.
    func recordSlot(id: String, controller: GCController, capabilities: ControllerCapabilities, family: PadFamily) {
        let name = controller.vendorName ?? controller.productCategory
        if let index = slots.firstIndex(where: { $0.id == id }) {
            slots[index].capabilities = capabilities
            slots[index].family = family
        } else {
            slots.append(Slot(id: id, name: name, capabilities: capabilities, family: family))
        }
        let extended = controller.extendedGamepad == nil ? "no" : "yes"
        let profile = Self.profileCensus(controller.physicalInputProfile)
        Self.log.info("""
        DEVCAPS id=\(id, privacy: .public) name=\(name, privacy: .public) \
        productCategory=\(controller.productCategory, privacy: .public) \
        vendorName=\(controller.vendorName ?? "none", privacy: .public) family=\(String(describing: family), privacy: .public) \
        extendedGamepad=\(extended, privacy: .public) motion=\(capabilities.hasMotion) touchpad=\(capabilities.hasTouchpad) \
        rumble=\(capabilities.hasRumble) lightbar=\(capabilities.hasLightbar) battery=\(capabilities.hasBattery) \
        triggerEffects=\(capabilities.hasTriggerEffects) playerLeds=\(capabilities.hasPlayerLeds) \
        \(profile, privacy: .public)
        """)
    }

    /// GameController coalesces simultaneous changes into one call, and the
    /// handler rebuilds the whole report from the snapshot every time.
    /// Nonisolated, so the compiler refuses a handler that reaches for
    /// main-actor state: it runs on the input queue.
    private nonisolated func installReportHandler(id: String, pad: GCExtendedGamepad) {
        pad.valueChangedHandler = { [weak self] pad, _ in
            self?.pushReport(id: id, pad: pad)
        }
    }

    private func detach(_ controller: GCController) {
        guard let id = controllerIds.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.physicalInputProfile.valueDidChangeHandler = nil
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
    nonisolated static func touchpadInputs(_ pad: GCExtendedGamepad) -> TouchpadInputs? {
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

    private nonisolated func pushReport(id: String, pad: GCExtendedGamepad) {
        let sample = Self.padSample(pad)
        processor.publish(deviceId: id, state: wireReport(sample))
    }

    /// The pad as GameController reads it, which is already the wire's
    /// orientation: both report a stick pushed up as positive y.
    nonisolated static func padSample(_ pad: GCExtendedGamepad) -> PadSample {
        PadSample(
            leftX: pad.leftThumbstick.xAxis.value,
            leftY: pad.leftThumbstick.yAxis.value,
            rightX: pad.rightThumbstick.xAxis.value,
            rightY: pad.rightThumbstick.yAxis.value,
            leftTrigger: pad.leftTrigger.value,
            rightTrigger: pad.rightTrigger.value,
            pressed: heldButtons(pad)
        )
    }

    nonisolated static func heldButtons(_ pad: GCExtendedGamepad) -> WireButtonWord {
        var word = WireButtonWord()
        for (input, button) in requiredButtons where pad[keyPath: input].isPressed {
            word.insert(button)
        }
        for (input, button) in optionalButtons where pad[keyPath: input]?.isPressed == true {
            word.insert(button)
        }
        return word
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
