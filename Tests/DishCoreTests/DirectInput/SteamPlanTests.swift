// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// What Dish writes to a Steam Controller as it starts and stops reading it:
/// the desktops' quiet and restore sequences for the 2015 pad, SDL's settings
/// for the 2026 one, and a receiver's slot asked or waited on first.
final class SteamPlanTests: XCTestCase {

    private func features(_ reports: [[UInt8]], id: UInt8) -> [SteamWrite] {
        reports.map { SteamWrite(kind: .feature, reportId: id, bytes: $0) }
    }

    func testTheModelNamesItsPlan() throws {
        let wired = try XCTUnwrap(directModel(vendorId: 0x28DE, productId: 0x1102))
        let puck = try XCTUnwrap(directModel(vendorId: 0x28DE, productId: 0x1304))
        XCTAssertEqual(steamPlan(wired), SteamPlan(generation: .original, receiver: false))
        XCTAssertEqual(steamPlan(puck), SteamPlan(generation: .triton, receiver: true))
        XCTAssertNil(try steamPlan(XCTUnwrap(directModel(vendorId: 0x057E, productId: 0x2009))))
    }

    func testAWired2015PadIsQuietedAtOnceAndRestoredOnRelease() {
        let plan = SteamPlan(generation: .original, receiver: false)
        XCTAssertEqual(plan.onClaim, features(steamConfigReports(.quiet), id: 0))
        XCTAssertEqual(plan.onConnect, features(steamConfigReports(.quiet), id: 0))
        XCTAssertEqual(plan.onRelease, features(steamConfigReports(.restore), id: 0))
        XCTAssertEqual(plan.refresh, [], "its quiet settings persist until it reboots")
    }

    func testA2015ReceiverAsksItsSlotWhatItHoldsAndQuietsTheControllerThatAnswers() {
        let plan = SteamPlan(generation: .original, receiver: true)
        XCTAssertEqual(plan.onClaim, features([steamReceiverStateRequest()], id: 0))
        XCTAssertEqual(plan.onConnect, features(steamConfigReports(.quiet), id: 0), "a returning pad has rebooted, its settings gone")
        XCTAssertEqual(plan.onRelease, features(steamConfigReports(.restore), id: 0))
    }

    func testA2026PadTurnsLizardModeOffAndItsImuOnAndRefreshesTheFirst() {
        let plan = SteamPlan(generation: .triton, receiver: false)
        let configure = features([tritonLizardOffReport(), tritonSensorsOnReport()], id: 1)
        XCTAssertEqual(plan.onClaim, configure)
        XCTAssertEqual(plan.onConnect, configure)
        XCTAssertEqual(plan.refresh, features([tritonLizardOffReport()], id: 1), "the firmware's watchdog turns it back on")
    }

    func testA2026PadIsReleasedByStoppingItsMotorsAndLettingTheWatchdogRestoreIt() {
        let plan = SteamPlan(generation: .triton, receiver: false)
        let stop = SteamWrite(kind: .output, reportId: 0x80, bytes: tritonRumbleReport(left: 0, right: 0))
        XCTAssertEqual(plan.onRelease, [stop], "SDL sends nothing on close: the watchdog re-enables lizard mode")
    }

    func testA2026ReceiverWaitsForItsControllersFirstReport() {
        let plan = SteamPlan(generation: .triton, receiver: true)
        XCTAssertEqual(plan.onClaim, [])
        XCTAssertEqual(plan.onConnect, features([tritonLizardOffReport(), tritonSensorsOnReport()], id: 1))
    }

    func testOnlyThe2026PadRefreshesAndRumbles() {
        XCTAssertTrue(SteamPlan(generation: .triton, receiver: true).refreshesLizardMode)
        XCTAssertTrue(SteamPlan(generation: .triton, receiver: false).rumbles)
        XCTAssertFalse(SteamPlan(generation: .original, receiver: false).refreshesLizardMode)
        XCTAssertFalse(SteamPlan(generation: .original, receiver: true).rumbles, "no motors on the 2015 pad")
    }
}
