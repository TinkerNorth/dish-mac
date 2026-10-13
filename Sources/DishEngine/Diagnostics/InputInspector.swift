// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The input inspector: one controller's input as the host sees it and as the
// pad sent it, motion and touch in human units, the report rate, and the
// stick tests (core StickHealth), all read off the processor's taps on the
// controller threads and folded into one state by a poll on the main actor.
// Nothing here measures twice: the taps see the very reports the host gets.

import Combine
import DishCore
import DishKernel
import Foundation

package struct MotionReadout: Hashable {
    package var gyroX: Float
    package var gyroY: Float
    package var gyroZ: Float
    package var accelX: Float
    package var accelY: Float
    package var accelZ: Float

    package init(gyroX: Float, gyroY: Float, gyroZ: Float, accelX: Float, accelY: Float, accelZ: Float) {
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
    }
}

package struct TouchFinger: Hashable {
    package var x: Float
    package var y: Float

    package init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

package struct TouchReadout: Hashable {
    package var finger1: TouchFinger?
    package var finger2: TouchFinger?
    package var click: Bool

    package init(finger1: TouchFinger?, finger2: TouchFinger?, click: Bool) {
        self.finger1 = finger1
        self.finger2 = finger2
        self.click = click
    }
}

/// What the inspector shows of one controller right now: the report as it
/// goes to the host (after the dead zones), the sticks as the pad sent them
/// (before them, what the stick tests read), motion and touch.
package struct InputSnapshot: Hashable {
    package var buttons: UInt16
    package var leftStick: StickSample
    package var rightStick: StickSample
    package var leftTrigger: Float
    package var rightTrigger: Float
    package var rawLeft: StickSample
    package var rawRight: StickSample
    package var motion: MotionReadout?
    package var touch: TouchReadout?

    package init(
        buttons: UInt16,
        leftStick: StickSample,
        rightStick: StickSample,
        leftTrigger: Float,
        rightTrigger: Float,
        rawLeft: StickSample,
        rawRight: StickSample,
        motion: MotionReadout?,
        touch: TouchReadout?
    ) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.rawLeft = rawLeft
        self.rawRight = rawRight
        self.motion = motion
        self.touch = touch
    }
}

/// The inspector's whole state; nothing while disarmed.
package struct InputInspection: Hashable {
    package var slotId: String?
    package var snapshot: InputSnapshot?
    package var reportsHz = 0
    package var bench = StickBench()
    package var secondsLeft = 0

    package init(
        slotId: String? = nil,
        snapshot: InputSnapshot? = nil,
        reportsHz: Int = 0,
        bench: StickBench = StickBench(),
        secondsLeft: Int = 0
    ) {
        self.slotId = slotId
        self.snapshot = snapshot
        self.reportsHz = reportsHz
        self.bench = bench
        self.secondsLeft = secondsLeft
    }

    package static let disarmed = InputInspection()
}

/// The latest of each stream for the armed slot: written on the controller
/// callback threads, read by the poll.
struct LatestInput: Equatable {
    var raw: GamepadReport?
    var filtered: GamepadReport?
    var motion: MotionSample?
    var touch: TouchpadSample?
    var reports: UInt64 = 0
}

@MainActor
package final class InputInspector: StateSource<InputInspection> {

    private let processor: GamepadInputProcessor
    private let now: () -> Int64
    private let pollMs: Int
    private let latest = LockedBox(LatestInput())
    private var rate = InputRateTracker()
    private var bench = StickBench()
    private var timer: DispatchSourceTimer?
    private var armedSlotId: String?

    /// The clock is injected, so a test drives the poll itself.
    init(processor: GamepadInputProcessor, now: @escaping () -> Int64 = uptimeMs, pollMs: Int = 50) {
        self.processor = processor
        self.now = now
        self.pollMs = pollMs
        super.init(initial: .disarmed)
    }

    /// Arms the inspector on one slot until `disarm`; arming another slot
    /// re-points it and drops the last one's stick test.
    package func arm(_ slotId: String) {
        armedSlotId = slotId
        latest.set(LatestInput())
        rate = InputRateTracker()
        bench = StickBench()
        installTaps(for: slotId)
        startPolling()
        setState(InputInspection(slotId: slotId))
    }

    package func disarm() {
        armedSlotId = nil
        processor.reportTap = nil
        processor.motionTap = nil
        processor.touchpadTap = nil
        timer?.cancel()
        timer = nil
        setState(.disarmed)
    }

    /// Ignored while no inspection is armed.
    package func startStickTest(_ kind: StickTestKind) {
        guard armedSlotId != nil else { return }
        bench.start(kind, nowMs: now())
        tick()
    }

    /// One poll: the latest samples folded into the state, the rate measured
    /// from the report count, the running test fed the raw sticks and
    /// advanced on the clock.
    package func tick() {
        guard let slotId = armedSlotId else { return }
        let input = latest.get()
        let nowMs = now()
        let hz = rate.sample(count: input.reports, nowUs: UInt64(max(nowMs, 0)) * 1000)
        if let raw = input.raw {
            bench.sample(left: InputReadout.stickSample(x: raw.lx, y: raw.ly), right: InputReadout.stickSample(x: raw.rx, y: raw.ry))
        }
        bench.advance(nowMs: nowMs)
        let inspection = InputInspection(
            slotId: slotId,
            snapshot: inputSnapshot(input),
            reportsHz: hz,
            bench: bench,
            secondsLeft: bench.secondsLeft(at: nowMs)
        )
        setState(inspection)
    }

    private func installTaps(for slotId: String) {
        let latest = latest
        processor.reportTap = { deviceId, raw, filtered in
            guard deviceId == slotId else { return }
            latest.mutate { input in
                input.raw = raw
                input.filtered = filtered
                input.reports += 1
            }
        }
        processor.motionTap = { deviceId, sample in
            guard deviceId == slotId else { return }
            latest.mutate { $0.motion = sample }
        }
        processor.touchpadTap = { deviceId, sample in
            guard deviceId == slotId else { return }
            latest.mutate { $0.touch = sample }
        }
    }

    private func startPolling() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(pollMs), repeating: .milliseconds(pollMs))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        source.resume()
        timer = source
    }
}

/// The snapshot a poll shows; nil until the pad's first report.
func inputSnapshot(_ input: LatestInput) -> InputSnapshot? {
    guard let filtered = input.filtered, let raw = input.raw else { return nil }
    return InputSnapshot(
        buttons: filtered.buttons,
        leftStick: InputReadout.stickSample(x: filtered.lx, y: filtered.ly),
        rightStick: InputReadout.stickSample(x: filtered.rx, y: filtered.ry),
        leftTrigger: InputReadout.triggerFraction(filtered.lt),
        rightTrigger: InputReadout.triggerFraction(filtered.rt),
        rawLeft: InputReadout.stickSample(x: raw.lx, y: raw.ly),
        rawRight: InputReadout.stickSample(x: raw.rx, y: raw.ry),
        motion: input.motion.map(motionReadout),
        touch: input.touch.map(touchReadout)
    )
}

func motionReadout(_ sample: MotionSample) -> MotionReadout {
    MotionReadout(
        gyroX: InputReadout.gyroDegreesPerSecond(sample.gyroX),
        gyroY: InputReadout.gyroDegreesPerSecond(sample.gyroY),
        gyroZ: InputReadout.gyroDegreesPerSecond(sample.gyroZ),
        accelX: InputReadout.accelG(sample.accelX),
        accelY: InputReadout.accelG(sample.accelY),
        accelZ: InputReadout.accelG(sample.accelZ)
    )
}

func touchReadout(_ sample: TouchpadSample) -> TouchReadout {
    TouchReadout(finger1: touchFinger(sample.finger0), finger2: touchFinger(sample.finger1), click: sample.buttonPressed)
}

private func touchFinger(_ finger: TouchpadFinger) -> TouchFinger? {
    guard finger.active else { return nil }
    return TouchFinger(x: InputReadout.touchFraction(finger.x), y: InputReadout.touchFraction(finger.y))
}
