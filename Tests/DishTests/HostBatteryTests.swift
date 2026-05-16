// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for the host-battery fallback's pure snapshot → wire mapping
/// (`HostBattery.reading(from:)`). When a controller doesn't surface a usable
/// battery, the sender reports the host Mac's battery instead; this function
/// is the only place where that decision turns into a `(level, status)` wire
/// tuple, so every branch is pinned here.
///
/// The IOKit half (`HostBattery.snapshot()`) is intentionally out of scope —
/// it would need a real power source to exercise, and the host the test runs
/// on could be either a laptop or a desktop. The mapping is what the wire
/// contract depends on.
final class HostBatteryTests: XCTestCase {

    // MARK: - No internal battery (desktop Mac)

    func testNilSnapshotMapsToWired() {
        // A Mac mini / Studio / Pro has no internal-battery power source, so
        // `snapshot()` returns nil. The controller is transitively
        // mains-powered → level=100, status=wired.
        let r = HostBattery.reading(from: nil)
        XCTAssertEqual(r.level, 100)
        XCTAssertEqual(r.status, .wired)
    }

    // MARK: - Laptop with a known percentage

    func testDischargingLaptopForwardsPercentage() {
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: 72, state: .discharging)
        )
        XCTAssertEqual(r.level, 72)
        XCTAssertEqual(r.status, .discharging)
    }

    func testChargingLaptopForwardsPercentage() {
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: 41, state: .charging)
        )
        XCTAssertEqual(r.level, 41)
        XCTAssertEqual(r.status, .charging)
    }

    func testFullLaptopForwardsPercentage() {
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: 100, state: .full)
        )
        XCTAssertEqual(r.level, 100)
        XCTAssertEqual(r.status, .full)
    }

    func testZeroPercentLaptopIsValid() {
        // 0 % is a real reading, not "unknown" — it must pass through as 0,
        // never collapse to 0xFF.
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: 0, state: .discharging)
        )
        XCTAssertEqual(r.level, 0)
        XCTAssertEqual(r.status, .discharging)
    }

    // MARK: - Clamping

    func testPercentageAbove100Clamps() {
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: 137, state: .charging)
        )
        XCTAssertEqual(r.level, 100)
        XCTAssertEqual(r.status, .charging)
    }

    func testNegativePercentageClampsToZero() {
        // A garbage negative capacity must not wrap when cast to UInt8.
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: -8, state: .discharging)
        )
        XCTAssertEqual(r.level, 0)
        XCTAssertEqual(r.status, .discharging)
    }

    // MARK: - Known state but unknown percentage

    func testNilPercentageMapsToUnknownLevel() {
        // The internal battery exists but isn't reporting capacity yet:
        // level=0xFF, but the charge state is still forwarded.
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: nil, state: .charging)
        )
        XCTAssertEqual(r.level, 0xFF)
        XCTAssertEqual(r.status, .charging)
    }

    func testNilPercentageWithUnknownState() {
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: nil, state: .unknown)
        )
        XCTAssertEqual(r.level, 0xFF)
        XCTAssertEqual(r.status, .unknown)
    }

    // MARK: - State mapping

    func testUnknownStateWithPercentage() {
        let r = HostBattery.reading(
            from: HostBattery.Snapshot(percentage: 55, state: .unknown)
        )
        XCTAssertEqual(r.level, 55)
        XCTAssertEqual(r.status, .unknown)
    }
}
