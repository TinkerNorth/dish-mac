// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation
import GameController
import os

/// Default per-axis deadzone applied to every newly-attached controller. The
/// magic numbers correspond to ~10 % of the int16 axis range and ~5 % of the
/// 0..255 trigger range — a conservative noise floor that keeps cheap pads
/// from twitching at rest without clipping deliberate small inputs. Mirrors
/// the per-device `flat` values Android pulls out of
/// `InputDevice.getMotionRange(axis).getFlat()`.
private let kDefaultStickFlat: Int16 = 3277
private let kDefaultTriggerFlat: UInt8 = 13

/// Bridges Apple's `GameController.framework` into the `GamepadInputProcessor`.
/// Hooks `valueChangedHandler` on every extended gamepad so we push a report
/// on every button/axis change — no polling, no per-frame loop. Mirrors the
/// `onInputDeviceAdded`/`dispatchGenericMotionEvent` flow on Android.
@MainActor
final class GameControllerInput: ObservableObject {

    private static let log = Logger(subsystem: "com.tinkernorth.dish", category: "GC")

    /// Published list of currently-connected controllers. One `Slot` per
    /// physical controller.
    struct Slot: Identifiable, Hashable {
        let id: String // stable controller id
        let name: String // vendorName or product category
    }

    @Published private(set) var slots: [Slot] = []

    let processor = GamepadInputProcessor()

    private var observers: [NSObjectProtocol] = []
    /// Weak back-reference for each active controller so we can unhook handlers.
    private var controllerIds: [ObjectIdentifier: String] = [:]

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            let strongSelf = self
            Task { @MainActor in strongSelf?.attach(controller) }
        })
        observers.append(nc.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            let strongSelf = self
            Task { @MainActor in strongSelf?.detach(controller) }
        })
        // Pick up any already-connected controllers on launch.
        for ctrl in GCController.controllers() {
            attach(ctrl)
        }
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Attach / detach

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let id = stableId(for: controller)
        controllerIds[ObjectIdentifier(controller)] = id
        let name = controller.vendorName ?? controller.productCategory

        if !slots.contains(where: { $0.id == id }) {
            slots.append(Slot(id: id, name: name))
        }

        // One-shot device-capability dump — mirrors the SatelliteJNI DEVCAPS
        // log on Android (PR #44/#47). Aimed at users reporting "my pad
        // doesn't work": ProductCategory tells us whether GameController
        // negotiated as Xbox / DualShock / DualSense / MFi / generic HID.
        Self.log.info("""
            DEVCAPS id=\(id, privacy: .public) name=\(name, privacy: .public) \
            category=\(controller.productCategory, privacy: .public) \
            extendedGamepad=yes hasButtonOptions=\(pad.buttonOptions != nil) \
            hasLeftThumbstickButton=\(pad.leftThumbstickButton != nil) \
            hasRightThumbstickButton=\(pad.rightThumbstickButton != nil)
            """)

        // Push the default deadzone profile straight away. The processor
        // applies these to every report from this device until/unless the
        // user overrides them in a future Settings UI.
        processor.setDeadzones(
            deviceId: id,
            .init(stickFlat: kDefaultStickFlat, triggerFlat: kDefaultTriggerFlat)
        )

        // The single master handler rebuilds the XUSB state from the current
        // snapshot whenever *anything* changes. GameController coalesces
        // multi-value changes into one handler call, matching the batched
        // MotionEvent the Android version processes per ACTION_MOVE.
        pad.valueChangedHandler = { [weak self] pad, _ in
            guard let self else { return }
            self.pushReport(id: id, pad: pad)
        }
    }

    private func detach(_ controller: GCController) {
        let oid = ObjectIdentifier(controller)
        guard let id = controllerIds.removeValue(forKey: oid) else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        slots.removeAll { $0.id == id }
        processor.remove(deviceId: id)
    }

    // MARK: - Hot path

    /// Called from GC's internal dispatch queue. Builds a full `DeviceState`
    /// from the current GCExtendedGamepad snapshot and hands it to the
    /// processor for immediate send.
    private nonisolated func pushReport(id: String, pad: GCExtendedGamepad) {
        var state = GamepadInputProcessor.DeviceState()

        // Face buttons — GameController normalises Xbox/PS/MFi to A/B/X/Y.
        if pad.buttonA.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.faceA }
        if pad.buttonB.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.faceB }
        if pad.buttonX.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.faceX }
        if pad.buttonY.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.faceY }
        if pad.leftShoulder.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.leftShoulder }
        if pad.rightShoulder.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.rightShoulder }
        if pad.buttonMenu.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.start }
        if pad.buttonOptions?.isPressed == true { state.wButtons |= GamepadInputProcessor.Buttons.back }
        if pad.leftThumbstickButton?.isPressed == true { state.wButtons |= GamepadInputProcessor.Buttons.leftThumb }
        if pad.rightThumbstickButton?.isPressed == true { state.wButtons |= GamepadInputProcessor.Buttons.rightThumb }

        // D-pad (digital).
        if pad.dpad.up.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.dpadUp }
        if pad.dpad.down.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.dpadDown }
        if pad.dpad.left.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.dpadLeft }
        if pad.dpad.right.isPressed { state.wButtons |= GamepadInputProcessor.Buttons.dpadRight }

        // Thumbsticks: GC gives -1..1, XUSB wants signed 16-bit. Y is inverted
        // on Android (scaleAxis uses -AXIS_MAX); GameController already flips
        // so "up = +1" — we negate to match the Android wire output.
        state.lx = scaleAxis(pad.leftThumbstick.xAxis.value, max: 32767)
        state.ly = scaleAxis(-pad.leftThumbstick.yAxis.value, max: 32767)
        state.rx = scaleAxis(pad.rightThumbstick.xAxis.value, max: 32767)
        state.ry = scaleAxis(-pad.rightThumbstick.yAxis.value, max: 32767)

        // Triggers.
        state.lt = scaleTrigger(pad.leftTrigger.value)
        state.rt = scaleTrigger(pad.rightTrigger.value)

        processor.publish(deviceId: id, state: state)
    }

    // MARK: - Helpers

    /// Build a stable per-launch id for a controller. GameController doesn't
    /// expose a persistent UUID pre-macOS 14, so we fall back to the vendor
    /// name + object address.
    private func stableId(for ctrl: GCController) -> String {
        if #available(macOS 14.0, *) {
            return ctrl.physicalInputProfile.description.isEmpty
                ? "\(ObjectIdentifier(ctrl).hashValue)"
                : "gc:\(ctrl.vendorName ?? "unknown"):\(ObjectIdentifier(ctrl).hashValue)"
        }
        return "gc:\(ctrl.vendorName ?? "unknown"):\(ObjectIdentifier(ctrl).hashValue)"
    }
}
