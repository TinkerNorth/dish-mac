// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
@testable import DishEngine

/// Routes that record instead of sending: `processor.route(recorder.route)`
/// gives every pad's feed a sink that writes down what the pad sent, on the
/// thread that sent it, for the test to read.
final class InputRecorder {
    /// One thing a pad sent, by device.
    enum Sent: Equatable {
        case report(String, GamepadReport)
        case motion(String, MotionSample, deltaUs: UInt32)
        case touchpad(String, TouchpadSample, eventTimeMs: UInt32)
        case battery(String, level: UInt8, status: BatteryStatus)
    }

    /// The switches every recorded route carries.
    var flags = ForwardingFlags()
    private let log = LockedBox<[Sent]>([])

    func route(_ deviceId: String) -> Route? {
        Route(sink: RecordingSink(deviceId: deviceId, log: log), flags: flags)
    }

    var sent: [Sent] {
        log.get()
    }

    var reports: [(id: String, report: GamepadReport)] {
        sent.compactMap { entry in
            guard case let .report(id, report) = entry else { return nil }
            return (id, report)
        }
    }

    var motion: [(id: String, sample: MotionSample, deltaUs: UInt32)] {
        sent.compactMap { entry in
            guard case let .motion(id, sample, deltaUs) = entry else { return nil }
            return (id, sample, deltaUs)
        }
    }

    var touches: [(id: String, sample: TouchpadSample, eventTimeMs: UInt32)] {
        sent.compactMap { entry in
            guard case let .touchpad(id, sample, eventTimeMs) = entry else { return nil }
            return (id, sample, eventTimeMs)
        }
    }

    var batteries: [(id: String, level: UInt8, status: BatteryStatus)] {
        sent.compactMap { entry in
            guard case let .battery(id, level, status) = entry else { return nil }
            return (id, level, status)
        }
    }
}

/// One device's recording sink.
private final class RecordingSink: InputSink {
    let deviceId: String
    let log: LockedBox<[InputRecorder.Sent]>

    init(deviceId: String, log: LockedBox<[InputRecorder.Sent]>) {
        self.deviceId = deviceId
        self.log = log
    }

    func sendReport(_ report: GamepadReport) {
        log.mutate { $0.append(.report(deviceId, report)) }
    }

    func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32) {
        log.mutate { $0.append(.motion(deviceId, sample, deltaUs: timestampDeltaUs)) }
    }

    func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32, scrollV _: Int16) {
        log.mutate { $0.append(.touchpad(deviceId, sample, eventTimeMs: eventTimeMs)) }
    }

    func sendBattery(level: UInt8, status: BatteryStatus) {
        log.mutate { $0.append(.battery(deviceId, level: level, status: status)) }
    }
}

extension GamepadInputProcessor {
    /// Routes every pad to closures that see what it sends, with its id, on
    /// the publishing thread: the shape the processor's senders had.
    func send(
        reports: ((String, GamepadReport) -> Void)? = nil,
        motion: ((String, MotionSample, UInt32) -> Void)? = nil,
        touchpad: ((String, TouchpadSample, UInt32, Int16) -> Void)? = nil,
        batteries: ((String, UInt8, UInt8) -> Void)? = nil
    ) {
        route { deviceId in
            let sink = ClosureSink(deviceId: deviceId, reports: reports, motion: motion, touchpad: touchpad, batteries: batteries)
            return Route(sink: sink, flags: ForwardingFlags())
        }
    }
}

/// One device's sink that hands each send to the test's closure.
private final class ClosureSink: InputSink {
    let deviceId: String
    let reports: ((String, GamepadReport) -> Void)?
    let motion: ((String, MotionSample, UInt32) -> Void)?
    let touchpad: ((String, TouchpadSample, UInt32, Int16) -> Void)?
    let batteries: ((String, UInt8, UInt8) -> Void)?

    init(
        deviceId: String,
        reports: ((String, GamepadReport) -> Void)?,
        motion: ((String, MotionSample, UInt32) -> Void)?,
        touchpad: ((String, TouchpadSample, UInt32, Int16) -> Void)?,
        batteries: ((String, UInt8, UInt8) -> Void)?
    ) {
        self.deviceId = deviceId
        self.reports = reports
        self.motion = motion
        self.touchpad = touchpad
        self.batteries = batteries
    }

    func sendReport(_ report: GamepadReport) {
        reports?(deviceId, report)
    }

    func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32) {
        motion?(deviceId, sample, timestampDeltaUs)
    }

    func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32, scrollV: Int16) {
        touchpad?(deviceId, sample, eventTimeMs, scrollV)
    }

    func sendBattery(level: UInt8, status: BatteryStatus) {
        batteries?(deviceId, level, status.rawValue)
    }
}
