// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class BatteryMappersTests: XCTestCase {

    private func reading(_ level: Int?, _ state: BatteryChargeState = .discharging) -> BatteryReading {
        BatteryReading(level: level, state: state)
    }

    func testChargingAndFullCountAsCharging() {
        XCTAssertTrue(batteryIsCharging(reading(50, .charging)))
        XCTAssertTrue(batteryIsCharging(reading(100, .full)))
        XCTAssertFalse(batteryIsCharging(reading(50, .discharging)))
        XCTAssertFalse(batteryIsCharging(reading(50, .unknown)))
    }

    func testTheSymbolStepsWithTheLevel() {
        let steps: [(Int, String)] = [
            (0, "battery.0"), (12, "battery.0"), (13, "battery.25"), (37, "battery.25"), (38, "battery.50"),
            (62, "battery.50"), (63, "battery.75"), (87, "battery.75"), (88, "battery.100"), (100, "battery.100")
        ]
        for (level, symbol) in steps {
            XCTAssertEqual(batterySymbol(reading(level)), symbol, "\(level)")
        }
    }

    func testTheSymbolForAnUnknownLevelAndWhileCharging() {
        XCTAssertEqual(batterySymbol(reading(nil)), "battery.50")
        XCTAssertEqual(batterySymbol(reading(10, .charging)), "battery.100.bolt")
        XCTAssertEqual(batterySymbol(reading(nil, .full)), "battery.100.bolt")
    }

    func testTheLevelTextIsAPercentageOrADash() {
        XCTAssertEqual(batteryLevelText(reading(73)), "73%")
        XCTAssertEqual(batteryLevelText(reading(nil)), "—")
    }

    func testTheTintWarnsAsTheLevelDrops() {
        XCTAssertEqual(batteryTint(reading(5, .charging)), DishTheme.success)
        XCTAssertEqual(batteryTint(reading(nil)), DishTheme.muted)
        XCTAssertEqual(batteryTint(reading(0)), DishTheme.error)
        XCTAssertEqual(batteryTint(reading(14)), DishTheme.error)
        XCTAssertEqual(batteryTint(reading(15)), DishTheme.warning)
        XCTAssertEqual(batteryTint(reading(29)), DishTheme.warning)
        XCTAssertEqual(batteryTint(reading(30)), DishTheme.muted)
        XCTAssertEqual(batteryTint(reading(100)), DishTheme.muted)
    }

    func testTheTooltipForEveryState() {
        XCTAssertEqual(batteryHelp(reading(100, .full)), "Battery full")
        XCTAssertEqual(batteryHelp(reading(40, .charging)), "Battery 40% — charging")
        XCTAssertEqual(batteryHelp(reading(nil, .charging)), "Battery charging")
        XCTAssertEqual(batteryHelp(reading(73, .discharging)), "Battery 73%")
        XCTAssertEqual(batteryHelp(reading(73, .unknown)), "Battery 73%")
        XCTAssertEqual(batteryHelp(reading(nil, .discharging)), "Battery level unknown")
        XCTAssertEqual(batteryHelp(reading(nil, .unknown)), "Battery level unknown")
    }
}
