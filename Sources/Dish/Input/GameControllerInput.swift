// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import CoreHaptics
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
/// Battery poll cadence — matches `BATTERY_REPORT_INTERVAL_SEC` (30 s) on
/// the satellite. The first sample is sent ~1 s after attach.
/// Module-internal (not file-private) so the battery timers in
/// `GameControllerInput+ReturnPath.swift` can read them.
let kBatteryPollIntervalSec = 30
let kBatteryFirstReportDelaySec = 1
/// Charging-state watch cadence. The protocol wants a battery report not only
/// every 30 s but ALSO "whenever the charging state transitions" — and
/// `GCDeviceBattery` has no change notification, so a transition can only be
/// observed by polling. This faster, lightweight tick reads only the state and
/// emits a report when it differs from the last observed state; it does not
/// send on an unchanged tick (the 30 s timer owns the steady cadence).
let kBatteryStateWatchIntervalSec = 3

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
        /// Hardware features detected at attach (gyro / touchpad / rumble /
        /// light bar / battery). Drives the capability chips in the slot card.
        var capabilities: ControllerCapabilities = .none
        /// Live battery reading, nil until the first poll completes.
        var battery: BatteryReading?
    }

    /// Module-internal setter (not `private(set)`) so the battery poll in
    /// `GameControllerInput+ReturnPath.swift` can refresh a slot's pill.
    @Published var slots: [Slot] = []

    let processor = GamepadInputProcessor()

    /// Per-device, per-finger monotonic touchpad tracking ids. `pushTouchpad`
    /// runs on a GC callback thread, so this is lock-guarded.
    private let touchpadIds = TouchpadTrackingState()

    private var observers: [NSObjectProtocol] = []
    /// Weak back-reference for each active controller so we can unhook handlers.
    private var controllerIds: [ObjectIdentifier: String] = [:]
    /// id → live `GCController`, populated on attach and pruned on detach so
    /// `applyRumble(deviceId:)` can resolve the haptics target without a
    /// linear scan of every connected controller every packet.
    /// Module-internal so the return-path extension can resolve targets.
    var controllersById: [String: GCController] = [:]
    /// Per-controller rumble actuator. Created lazily on first `applyRumble`
    /// call so we don't pay the engine-startup cost for controllers the
    /// satellite never rumbles. Cleaned up in `detach`.
    var actuators: [String: RumbleActuator] = [:]
    /// Per-device polling timer that emits a battery snapshot every
    /// `kBatteryPollIntervalSec` seconds. macOS GCDevice doesn't surface a
    /// "battery state changed" notification, so we poll — and the timer is
    /// also the wire cadence: MSG_BATTERY is a fixed 30 s heartbeat. Polling
    /// is light (one Float read + an enum compare) and only runs while the
    /// controller is attached.
    /// Module-internal so the battery timers in the return-path extension can
    /// register and cancel them.
    var batteryTimers: [String: DispatchSourceTimer] = [:]
    /// Per-device faster timer that watches for a charging-state transition
    /// and fires an out-of-cadence battery report when one happens — the
    /// protocol requires a report on every transition, not just the 30 s tick.
    var batteryStateTimers: [String: DispatchSourceTimer] = [:]
    /// Last battery `statusRaw` forwarded per device. Drives both the 30 s
    /// tick's record-keeping and the state-watch timer's transition detection.
    var lastBatteryStatusRaw: [String: UInt8] = [:]

    init() {
        let nc = NotificationCenter.default
        // The observer closures run on `.main` (NotificationCenter delivers
        // there), but `attach`/`detach` are `@MainActor` so a hop through a
        // `Task` is still needed. `self` is rebound into a `let` outside the
        // `Task` because Swift 5.9 forbids referencing the closure's captured
        // `var self` from concurrently-executing code.
        observers.append(nc.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            Task { @MainActor in self.attach(controller) }
        })
        observers.append(nc.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            Task { @MainActor in self.detach(controller) }
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
        // Reuse the existing id if this exact controller object is already
        // attached (the launch sweep + `GCControllerDidConnect` can both fire
        // for one pad); only mint a fresh id for a genuinely new object, so a
        // re-attach can't be misread as a second identical pad.
        let id = controllerIds[ObjectIdentifier(controller)] ?? stableId(for: controller)
        controllerIds[ObjectIdentifier(controller)] = id
        controllersById[id] = controller
        let name = controller.vendorName ?? controller.productCategory

        // Detect what the hardware exposes. `motion`, `haptics`, `battery`,
        // and `light` are all optional on GCController; the touchpad lives on
        // the DualSense / DualShock subclasses of GCExtendedGamepad.
        let touchpad = Self.touchpadInputs(pad)
        // `hasBattery` is always true: a pad without its own `GCDeviceBattery`
        // still gets a reading from the host-Mac fallback, so the slot card's
        // battery pill always has something to show.
        let caps = ControllerCapabilities(
            hasMotion: controller.motion != nil,
            hasTouchpad: touchpad != nil,
            hasRumble: controller.haptics != nil,
            hasLightbar: controller.light != nil,
            hasBattery: true
        )

        if let idx = slots.firstIndex(where: { $0.id == id }) {
            slots[idx].capabilities = caps
        } else {
            slots.append(Slot(id: id, name: name, capabilities: caps))
        }

        // One-shot device-capability dump — mirrors the SatelliteJNI DEVCAPS
        // log on Android (PR #44/#47). Aimed at users reporting "my pad
        // doesn't work": ProductCategory tells us whether GameController
        // negotiated as Xbox / DualShock / DualSense / MFi / generic HID.
        Self.log.info("""
        DEVCAPS id=\(id, privacy: .public) name=\(name, privacy: .public) \
        category=\(controller.productCategory, privacy: .public) \
        extendedGamepad=yes motion=\(caps.hasMotion) touchpad=\(caps.hasTouchpad) \
        rumble=\(caps.hasRumble) lightbar=\(caps.hasLightbar) battery=\(caps.hasBattery)
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

        // Motion (IMU). Optional — only DualSense, DualShock 4, MFi pads
        // with an IMU surface this. We hook the motion's own
        // `valueChangedHandler`; rate is bounded by GCMotion (typically
        // 200–500 Hz on DualSense), well under the 1 kHz cap senders are
        // permitted.
        if let motion = controller.motion {
            // Some controllers (per `GCMotion.sensorsRequireManualActivation`)
            // emit NO motion callbacks until `sensorsActive` is opted in — the
            // sensors stay powered down to save controller battery / Bluetooth
            // bandwidth. Without this, motion silently never fires on those
            // pads even though the slot card shows a "Gyro" chip. Pads that
            // self-manage their sensors (Siri Remote, etc.) report
            // `sensorsRequireManualActivation == false` and need no opt-in.
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            motion.valueChangedHandler = { [weak self] motion in
                guard let self else { return }
                // Gate each surface on its own availability flag: a pad that
                // exposes only some surfaces must not emit zeros for the rest
                // as if they were real readings. `pushMotion` reads gyro from
                // `rotationRate` and accel from `gravity`/`userAcceleration`.
                let haveGyro = motion.hasRotationRate
                let haveAccel = motion.hasGravityAndUserAcceleration
                guard haveGyro || haveAccel else { return }
                self.pushMotion(
                    id: id,
                    motion: motion,
                    haveGyro: haveGyro,
                    haveAccel: haveAccel
                )
            }
        }

        // Touchpad (DualSense / DualShock 4 only). GameController models the
        // pad as two `GCControllerDirectionPad`s plus a clicky button. There
        // is no per-finger touch-down event, so each of the three inputs'
        // `valueChangedHandler`s funnels into a single `pushTouchpad` that
        // re-reads the whole touchpad state — same "rebuild from snapshot"
        // shape as `pushReport`.
        if let touchpad {
            let rebuild: (Any) -> Void = { [weak self] _ in
                guard let self else { return }
                self.pushTouchpad(
                    id: id,
                    primary: touchpad.primary,
                    secondary: touchpad.secondary,
                    button: touchpad.button
                )
            }
            touchpad.primary.valueChangedHandler = { dpad, _, _ in rebuild(dpad) }
            touchpad.secondary.valueChangedHandler = { dpad, _, _ in rebuild(dpad) }
            touchpad.button.valueChangedHandler = { btn, _, _ in rebuild(btn) }
        }

        // Battery. The timer runs for *every* controller: a pad with its own
        // `GCDeviceBattery` reports that, and one without (wired Xbox pads
        // return nil, as do pads whose level reads unknown) falls back to the
        // host Mac's battery via `HostBattery`. The first sample is delayed by
        // `kBatteryFirstReportDelaySec` so the satellite has ACK'd the
        // controller-add by the time it arrives; subsequent samples follow
        // `kBatteryPollIntervalSec`.
        startBatteryTimer(deviceId: id, controller: controller)
    }

    private func detach(_ controller: GCController) {
        let oid = ObjectIdentifier(controller)
        guard let id = controllerIds.removeValue(forKey: oid) else { return }
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
        if let timer = batteryTimers.removeValue(forKey: id) {
            timer.cancel()
        }
        if let timer = batteryStateTimers.removeValue(forKey: id) {
            timer.cancel()
        }
        lastBatteryStatusRaw.removeValue(forKey: id)
        touchpadIds.remove(deviceId: id)
    }

    /// Resolve a `GCExtendedGamepad` to its touchpad inputs, if it has any.
    /// Only the DualSense and DualShock 4 subclasses expose a touchpad.
    private static func touchpadInputs(
        _ pad: GCExtendedGamepad
    ) -> (
        primary: GCControllerDirectionPad,
        secondary: GCControllerDirectionPad,
        button: GCControllerButtonInput
    )? {
        if let ds = pad as? GCDualSenseGamepad {
            return (ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton)
        }
        if let ds4 = pad as? GCDualShockGamepad {
            return (ds4.touchpadPrimary, ds4.touchpadSecondary, ds4.touchpadButton)
        }
        return nil
    }

    // MARK: - Touchpad

    /// Rebuild the full touchpad state and hand it to the processor. Called
    /// from any of the three touchpad inputs' callback queues.
    ///
    /// GameController has no per-finger touch-down signal — the framework
    /// reports each contact as a direction pad that reads (0, 0) when no
    /// finger is present. We therefore treat a finger as "active" when its
    /// pad value is non-zero. The edge case (a finger resting exactly at the
    /// pad centre) reads as inactive; this is the best signal the framework
    /// exposes and matches how GCDualSense touchpad consumers behave. Finger
    /// IDs aren't surfaced either, so we use the stable slot indices 0 / 1.
    ///
    /// The MSG_TOUCHPAD wire frame is centre-origin with `+y` pointing *down*
    /// (see satellite/docs/contract.md). GameController's direction-pad y-axis
    /// points up, so the y-axis is negated here — the same flip the thumbstick
    /// path applies — keeping the macOS sender consistent with the SDL senders.
    private nonisolated func pushTouchpad(
        id: String,
        primary: GCControllerDirectionPad,
        secondary: GCControllerDirectionPad,
        button: GCControllerButtonInput
    ) {
        let p0Active = primary.xAxis.value != 0 || primary.yAxis.value != 0
        let p1Active = secondary.xAxis.value != 0 || secondary.yAxis.value != 0
        // `gcTouchpadAxisToWire` applies the centre-origin frame + the `+y`
        // DOWN negation the wire wants; pure so the flip is unit-tested.
        let f0 = gcTouchpadAxisToWire(x: primary.xAxis.value, y: primary.yAxis.value)
        let f1 = gcTouchpadAxisToWire(x: secondary.xAxis.value, y: secondary.yAxis.value)
        // Resolve the monotonic per-finger tracking ids — each bumps on a fresh
        // contact (false → true edge). GameController surfaces no native id.
        let ids = touchpadIds.advance(
            deviceId: id,
            finger0Active: p0Active,
            finger1Active: p1Active
        )
        processor.publishTouchpad(
            deviceId: id,
            sample: TouchpadSample(
                finger0: TouchpadFinger(active: p0Active, id: ids.finger0, x: f0.x, y: f0.y),
                finger1: TouchpadFinger(active: p1Active, id: ids.finger1, x: f1.x, y: f1.y),
                buttonPressed: button.isPressed
            )
        )
    }

    // MARK: - Return-path state (used by GameControllerInput+ReturnPath.swift)

    /// RGB colour, the `ReturnPathApplier` payload for the light-bar path.
    /// A stored-property closure can't live in an extension, so the applier
    /// and its payload type stay here; the `applyLightbar` entry point that
    /// feeds it is in `GameControllerInput+ReturnPath.swift`.
    struct LightbarColor {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    /// Serialises the light-bar return path: FIFO ordering + per-controller
    /// last-colour-wins coalescing, so a game setting a colour every frame
    /// can't latch a stale colour or pile up unstructured tasks. See
    /// `ReturnPathApplier`. `lazy` so the queue is only created on the first
    /// inbound lightbar packet.
    lazy var lightbarApplier = ReturnPathApplier<LightbarColor>(
        label: "dish.returnpath.lightbar"
    ) { [weak self] deviceId, color in
        guard let self,
              let controller = self.controllersById[deviceId],
              let light = controller.light else { return }
        light.color = GCColor(
            red: Float(color.r) / 255.0,
            green: Float(color.g) / 255.0,
            blue: Float(color.b) / 255.0
        )
    }

    // MARK: - Motion (IMU)

    /// Called from GCMotion's callback queue. Reads the gyroscope and the
    /// gravity-decomposed acceleration, converts to the wire frame via the
    /// pure `gcMotionToWire`, and hands off to the processor (which timestamps
    /// and dispatches via `motionSender`).
    ///
    /// Coordinate convention — evidence-backed against Apple's
    /// `GameController/GCMotion.h` SDK header:
    ///
    ///  * `GCRotationRate` (the type of `motion.rotationRate`): each field is
    ///    "rotation rate in radians/second. The sign follows the right hand
    ///    rule" — explicitly documented per-axis. The frame is therefore
    ///    right-handed.
    ///  * `GCAcceleration` (the type of `motion.gravity` / `userAcceleration`):
    ///    "a device held at rest with the z axis aligned with the azimuth
    ///    [(0,0,1), i.e. up] is assumed to have gravitation applying the vector
    ///    (0, 0, -1)." So `gravity` is the gravitational *load* vector (points
    ///    toward the ground) and the axes are right-handed with `+X` = right,
    ///    `+Y` = up, `+Z` = toward the player — the same right-handed DSU frame
    ///    `satellite/docs/contract.md` §0x000A specifies. The axes map 1:1, so
    ///    no per-axis rotation is applied; `gcMotionToWire` documents the rest
    ///    (including why accel is `userAcceleration - gravity`, not their sum).
    ///
    /// `haveGyro` / `haveAccel` come from the pad's `hasRotationRate` /
    /// `hasGravityAndUserAcceleration` flags (checked by the caller in
    /// `attach`). A surface the pad lacks is sent as zeros rather than a stale
    /// or fabricated reading.
    private nonisolated func pushMotion(
        id: String,
        motion: GCMotion,
        haveGyro: Bool,
        haveAccel: Bool
    ) {
        let rate = motion.rotationRate
        let gravity = motion.gravity
        let userAccel = motion.userAcceleration
        let wire = gcMotionToWire(
            rotationRateRad: haveGyro ? MotionAxes(x: rate.x, y: rate.y, z: rate.z) : .zero,
            gravity: haveAccel ? MotionAxes(x: gravity.x, y: gravity.y, z: gravity.z) : .zero,
            userAccel: haveAccel ? MotionAxes(x: userAccel.x, y: userAccel.y, z: userAccel.z) : .zero
        )

        processor.publishMotion(
            deviceId: id,
            gyroX: wire.gyroX,
            gyroY: wire.gyroY,
            gyroZ: wire.gyroZ,
            accelX: wire.accelX,
            accelY: wire.accelY,
            accelZ: wire.accelZ
        )
    }

    /// Motor magnitudes + duration, the `ReturnPathApplier` payload for rumble.
    /// Kept here alongside `rumbleApplier` — its stored-property closure can't
    /// live in an extension; `applyRumble` is in the return-path extension.
    struct RumbleCommand {
        let strong: UInt16
        let weak: UInt16
        let durationMs: UInt16
    }

    /// Serialises the rumble return path: FIFO ordering + per-controller
    /// last-command-wins coalescing, so a game holding the motors across
    /// frames can't pile up unstructured tasks or apply commands out of
    /// order. See `ReturnPathApplier`. `lazy` — the queue is created on the
    /// first inbound rumble packet.
    lazy var rumbleApplier = ReturnPathApplier<RumbleCommand>(
        label: "dish.returnpath.rumble"
    ) { [weak self] deviceId, cmd in
        guard let self,
              let controller = self.controllersById[deviceId] else { return }
        // Lazily create the actuator so we don't allocate haptics engines
        // for controllers a satellite never rumbles.
        let actuator: RumbleActuator
        if let existing = self.actuators[deviceId] {
            actuator = existing
        } else if let fresh = RumbleActuator(controller: controller) {
            self.actuators[deviceId] = fresh
            actuator = fresh
        } else {
            return // controller doesn't expose haptics
        }
        actuator.apply(strong: cmd.strong, weak: cmd.weak, durationMs: cmd.durationMs)
    }

    /// IOKit snapshot of the host Mac's battery runs off the main thread.
    /// `HostBattery.snapshot()` is a synchronous IOKit call; hopping it here
    /// keeps the battery poll (every 30 s per wired controller) off the main
    /// runloop. Only the `slots` update is bounced back to the main actor.
    /// The battery timers that use it are in the return-path extension.
    let batteryWorkQueue = DispatchQueue(
        label: "dish.battery.iokit", qos: .utility
    )

    /// Wire-encoded battery reading plus the slot-card display state, the
    /// common shape `emitBattery` builds from either the controller's own
    /// `GCDeviceBattery` or the host-Mac fallback.
    struct BatteryResolution {
        let level: UInt8
        let statusRaw: UInt8
        let displayState: BatteryChargeState
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

    /// Build a controller id that is **stable across an unplug/replug** so the
    /// slot binding survives a reconnect.
    ///
    /// The id must NOT be derived from `ObjectIdentifier(ctrl)` — GameController
    /// vends a fresh `GCController` object on every reconnect, so an
    /// address-based id changes on replug and the slot binding is dropped.
    ///
    /// GameController on macOS exposes no per-physical-unit identifier — no
    /// vendor/product ID, no persistent UUID, on any OS version (the previous
    /// `#available(macOS 14)` branch keyed off `physicalInputProfile.description`,
    /// which is never empty, so it was dead code and still used the unstable
    /// address). The most stable property available is `vendorName` +
    /// `productCategory`, which is identical for a given controller model
    /// across reconnects. We key on that.
    ///
    /// Two physically-identical pads share that key, so when one is already
    /// attached we append the lowest free ordinal — the disambiguated id is
    /// still stable while that pad stays connected, and a single pad always
    /// reuses the ordinal-free id across replug.
    private func stableId(for ctrl: GCController) -> String {
        let vendor = ctrl.vendorName ?? "unknown"
        let base = "gc:\(vendor):\(ctrl.productCategory)"
        let attached = Set(controllerIds.values)
        if !attached.contains(base) { return base }
        var ordinal = 1
        while attached.contains("\(base)#\(ordinal)") {
            ordinal += 1
        }
        return "\(base)#\(ordinal)"
    }
}
