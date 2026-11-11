// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The battery a pad's MSG_BATTERY carries: the lower of the pad's own and
/// the Mac's, whatever the link, the unknown level sorting above every known
/// one, a tie going to the pad, and the status travelling with the winner.
final class BatteryRoutingTests: XCTestCase {

    private let unknown = ProtocolConstants.batteryLevelUnknown

    func testAWiredPadLowerThanTheMacSendsThePadsSample() {
        let pad = PadBattery(level: 40, status: .charging)
        let mac = PadBattery(level: 80, status: .discharging)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), pad)
    }

    func testAWiredPadHigherThanTheMacSendsTheMacs() {
        let pad = PadBattery(level: 90, status: .full)
        let mac = PadBattery(level: 30, status: .discharging)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), mac)
    }

    func testAPadWithNoBatterySendsTheMacs() {
        let mac = PadBattery(level: 64, status: .charging)
        XCTAssertEqual(lowestBattery(pad: nil, host: mac), mac)
    }

    func testAnUnknownMacAndAKnownPadSendThePads() {
        let pad = PadBattery(level: 55, status: .discharging)
        let mac = PadBattery(level: unknown, status: .unknown)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), pad)
    }

    func testAPadOfUnknownLevelSendsTheMacs() {
        let pad = PadBattery(level: unknown, status: .charging)
        let mac = PadBattery(level: 60, status: .discharging)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), mac)
    }

    func testOnATieThePadsSampleWinsWithItsStatus() {
        let pad = PadBattery(level: 50, status: .charging)
        let mac = PadBattery(level: 50, status: .discharging)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), pad, "the status is the pad's, not the Mac's")
    }

    func testTwoUnknownLevelsTieAndThePadWins() {
        let pad = PadBattery(level: unknown, status: .charging)
        let mac = PadBattery(level: unknown, status: .unknown)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), pad)
    }

    func testADesktopMacOnMainsLosesToAnyPadBelowFull() {
        let mac = PadBattery(level: 100, status: .wired)
        let pad = PadBattery(level: 99, status: .discharging)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), pad)
        XCTAssertEqual(lowestBattery(pad: nil, host: mac), mac, "a pad with no battery still reports the Mac on mains")
    }

    func testAnEmptyPadBeatsAnyMac() {
        let pad = PadBattery(level: 0, status: .discharging)
        let mac = PadBattery(level: 1, status: .discharging)
        XCTAssertEqual(lowestBattery(pad: pad, host: mac), pad)
    }
}
