// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// Preparing a report: loading while the hosts are asked, then what they
/// said and the Mac's conditions together.
private let preparedConditions = BundleDeviceConditions(
    battery: BundleBattery(level: 50, charging: true),
    thermal: .fair,
    powerSave: true,
    wifi: nil
)

@Sendable
private func readPreparedConditions() -> BundleDeviceConditions {
    preparedConditions
}

@MainActor
final class ReportPreparationSourceTests: XCTestCase {

    func testItRestsIdleUntilAsked() {
        let source = ReportPreparationSource(snapshots: { [:] }, conditions: .none)
        XCTAssertEqual(source.state.phase, .idle)
    }

    func testPreparingLoadsThenHoldsTheHostsAndTheConditions() async {
        let source = ReportPreparationSource(
            snapshots: { ["sat": .failed(.olderSatellite)] },
            conditions: DeviceConditionsReading(read: readPreparedConditions)
        )
        source.prepare()
        XCTAssertTrue(source.state.isLoading)
        await source.settled()
        XCTAssertTrue(source.state.isSuccess)
        XCTAssertEqual(source.state.data, ReportPreparation(snapshots: ["sat": .failed(.olderSatellite)], conditions: preparedConditions))
    }

    func testPreparingAgainKeepsTheLastWhileItLoads() async {
        let source = ReportPreparationSource(snapshots: { [:] }, conditions: .none)
        source.prepare()
        await source.settled()
        source.prepare()
        XCTAssertTrue(source.state.isLoading)
        XCTAssertEqual(source.state.data?.conditions, .unknown)
        await source.settled()
        XCTAssertTrue(source.state.isSuccess)
    }
}
