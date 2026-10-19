// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Where a bound slot's input goes: a satellite session, or one pad on a
/// Moonlight host. Called on the controller callback threads, once per
/// event, after the routing table's one locked read.
protocol InputSink: AnyObject {
    func sendReport(_ report: GamepadReport)
    func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32)
    func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32)
    func sendBattery(level: UInt8, status: BatteryStatus)
}

extension WifiConnection: InputSink {}

/// One pad on a Moonlight host, as the routing table targets it: the slot's
/// input onto the host's link, which knows the pad's number.
final class MoonlightPadSink: InputSink {
    let link: MoonlightPadLink
    let slotId: String

    init(link: MoonlightPadLink, slotId: String) {
        self.link = link
        self.slotId = slotId
    }

    func sendReport(_ report: GamepadReport) {
        link.sendReport(slotId, report)
    }

    /// The host paces motion itself, per pad and type; the satellite's
    /// timestamp delta has no field on this wire.
    func sendMotion(_ sample: MotionSample, timestampDeltaUs _: UInt32) {
        link.sendMotion(slotId, sample)
    }

    func sendTouchpad(sample: TouchpadSample, eventTimeMs _: UInt32) {
        link.sendTouchpad(slotId, sample: sample)
    }

    func sendBattery(level: UInt8, status: BatteryStatus) {
        link.sendBattery(slotId, level: level, status: status)
    }
}
