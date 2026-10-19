// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
@testable import DishEngine

/// Records what a link sends, in order, from any thread.
class RecordingPadSender: MoonlightPadSending, @unchecked Sendable {
    enum Sent: Equatable {
        case state(MoonlightInput.PadFrame)
        case arrival(MoonlightInput.PadArrival)
        case replug(UInt8, UInt16, MoonlightInput.PadArrival)
        case touch(UInt8, MoonlightTouchEmission)
        case motion(UInt8, UInt8, Float, Float, Float)
        case battery(UInt8, UInt8, UInt8)
    }

    private let box = LockedBox<[Sent]>([])

    var sent: [Sent] {
        box.get()
    }

    func take() -> [Sent] {
        box.mutate { sent in
            let out = sent
            sent = []
            return out
        }
    }

    func sendControllerState(_ frame: MoonlightInput.PadFrame) {
        box.mutate { $0.append(.state(frame)) }
    }

    func sendControllerArrival(_ arrival: MoonlightInput.PadArrival) {
        box.mutate { $0.append(.arrival(arrival)) }
    }

    func sendControllerReplug(number: UInt8, otherPadsMask: UInt16, arrival: MoonlightInput.PadArrival) {
        box.mutate { $0.append(.replug(number, otherPadsMask, arrival)) }
    }

    func sendControllerTouch(controller: UInt8, emission: MoonlightTouchEmission) {
        box.mutate { $0.append(.touch(controller, emission)) }
    }

    func sendControllerMotion(controller: UInt8, type: UInt8, x: Float, y: Float, z: Float) {
        box.mutate { $0.append(.motion(controller, type, x, y, z)) }
    }

    func sendControllerBattery(controller: UInt8, state: UInt8, percentage: UInt8) {
        box.mutate { $0.append(.battery(controller, state, percentage)) }
    }
}

/// A recording sender that also plays the live session: it counts the
/// clock's ticks and remembers being stopped.
final class RecordingLiveSession: RecordingPadSender, MoonlightLiveSession, @unchecked Sendable {
    private let tickCount = AtomicInt(0)
    private let stoppedFlag = AtomicBool(false)

    var roundTripMs: Int64? {
        7
    }

    var linkReport: String {
        "recording"
    }

    var ticks: Int {
        tickCount.get()
    }

    var stopped: Bool {
        stoppedFlag.get()
    }

    func tick() {
        _ = tickCount.incrementAndGet()
    }

    func stop() {
        stoppedFlag.set(true)
    }
}
