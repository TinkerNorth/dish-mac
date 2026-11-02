// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Where a bound slot's input goes: a satellite session, or one pad on a
/// Moonlight host. Called on the thread that publishes the pad, once per
/// event, through the route its feed holds.
protocol InputSink: AnyObject {
    func sendReport(_ report: GamepadReport)
    func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32)
    func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32)
    func sendBattery(level: UInt8, status: BatteryStatus)
}

/// One pad on a satellite, as the routing table targets it: the slot's
/// input onto the session, under the controller index the pad holds there.
final class SatellitePadSink: InputSink {
    let connection: WifiConnection
    let controllerIndex: Int

    init(connection: WifiConnection, controllerIndex: Int) {
        self.connection = connection
        self.controllerIndex = controllerIndex
    }

    func sendReport(_ report: GamepadReport) {
        connection.sendReport(report, controllerIndex: controllerIndex)
    }

    func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32) {
        connection.sendMotion(sample, timestampDeltaUs: timestampDeltaUs, controllerIndex: controllerIndex)
    }

    func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32) {
        connection.sendTouchpad(sample: sample, eventTimeMs: eventTimeMs, controllerIndex: controllerIndex)
    }

    func sendBattery(level: UInt8, status: BatteryStatus) {
        connection.sendBattery(level: level, status: status, controllerIndex: controllerIndex)
    }
}

/// One pad on a satellite's live client, as a feed's route holds it: the
/// report goes straight to the client under the pad's index.
final class SatelliteClientSink: InputSink {
    let client: SatelliteClient
    let controllerIndex: Int

    init(client: SatelliteClient, controllerIndex: Int) {
        self.client = client
        self.controllerIndex = controllerIndex
    }

    func sendReport(_ report: GamepadReport) {
        client.sendReport(controllerIndex: controllerIndex, report: report)
    }

    func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32) {
        client.sendMotion(controllerIndex: controllerIndex, sample: sample, timestampDeltaUs: timestampDeltaUs)
    }

    func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32) {
        client.sendTouchpad(controllerIndex: controllerIndex, sample: sample, eventTimeMs: eventTimeMs)
    }

    func sendBattery(level: UInt8, status: BatteryStatus) {
        client.sendBattery(controllerIndex: controllerIndex, level: level, status: status)
    }
}

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
