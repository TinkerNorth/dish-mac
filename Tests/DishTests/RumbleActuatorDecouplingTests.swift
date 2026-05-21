// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Guards that `RumbleActuator` drives vibration only and never reaches into
/// the light bar.
///
/// `RumbleActuator.apply` runs the haptics for one physical controller. Its
/// behaviour can't be exercised in a unit test — `init?` needs a live
/// `GCController` exposing `haptics`, and CoreHaptics has no headless mode.
/// What *can* be pinned is that the actuator never touches the light bar:
/// that separation is a structural property of the source.
///
/// So this test asserts, at the source level, that `RumbleActuator.swift`
/// contains no `light.color` / `GCColor` write. If a future change couples
/// them, this fails. The companion behavioural coverage (which sink a packet
/// drives, under which toggle) lives in `ReturnPathRoutingTests`.
final class RumbleActuatorDecouplingTests: XCTestCase {

    /// Absolute path to `Sources/Dish/Input/RumbleActuator.swift`, derived
    /// from this test file's compile-time location so it resolves no matter
    /// where the test bundle is run from.
    private func rumbleActuatorSource() throws -> String {
        // #filePath → .../dish-mac/Tests/DishTests/RumbleActuatorDecouplingTests.swift
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile // .../RumbleActuatorDecouplingTests.swift
            .deletingLastPathComponent() // .../DishTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // .../dish-mac
        let source = repoRoot
            .appendingPathComponent("Sources/Dish/Input/RumbleActuator.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "RumbleActuator.swift was empty or unreadable")
        return text
    }

    /// Strip `//`-comments and doc comments so the structural assertions below
    /// only inspect *code*, not the prose explaining the separation (which
    /// legitimately still mentions the light bar).
    private func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") {
                    return line[line.startIndex ..< range.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    func testRumbleActuatorDoesNotWriteLightColor() throws {
        let code = try codeOnly(rumbleActuatorSource())
        XCTAssertFalse(
            code.contains("light.color"),
            "RumbleActuator must not write `light.color` — the light bar is a separate return path"
        )
        XCTAssertFalse(
            code.contains(".color ="),
            "RumbleActuator must not assign any `.color` — vibration only"
        )
    }

    func testRumbleActuatorDoesNotConstructGCColor() throws {
        let code = try codeOnly(rumbleActuatorSource())
        XCTAssertFalse(
            code.contains("GCColor"),
            "RumbleActuator must not construct a `GCColor` — light-bar work lives in applyLightbar"
        )
    }

    func testRumbleActuatorApplyHasNoLightbarParameters() throws {
        let code = try codeOnly(rumbleActuatorSource())
        // `apply` takes only the three vibration arguments.
        XCTAssertTrue(
            code.contains("func apply(strong: UInt16, weak: UInt16, durationMs: UInt16)"),
            "RumbleActuator.apply must carry only the strong/weak/durationMs vibration arguments"
        )
    }

    func testRumbleActuatorStillDrivesHaptics() throws {
        // Sanity check the negative assertions above aren't passing simply
        // because the file was gutted: the haptics path must still be here.
        let code = try codeOnly(rumbleActuatorSource())
        XCTAssertTrue(code.contains("CHHapticEngine"), "haptics engine code missing")
        XCTAssertTrue(code.contains("func apply"), "apply(...) missing")
    }
}

/// `ControllerCapabilities.hasLightbar` backs both the "Lightbar" slot-card
/// chip and the `CAP_LIGHTBAR` advertisement.
final class ControllerCapabilitiesLightbarTests: XCTestCase {

    func testNoneHasLightbarFalse() {
        XCTAssertFalse(ControllerCapabilities.none.hasLightbar)
    }

    func testHasLightbarIsIndependentOfOtherCapabilities() {
        // A pad with a light bar but nothing else, and the converse — the
        // flag must not be entangled with rumble/motion/touchpad.
        var caps = ControllerCapabilities()
        caps.hasLightbar = true
        XCTAssertTrue(caps.hasLightbar)
        XCTAssertFalse(caps.hasRumble)
        XCTAssertFalse(caps.hasMotion)
        XCTAssertFalse(caps.hasTouchpad)

        let rumbleOnly = ControllerCapabilities(
            hasMotion: false,
            hasTouchpad: false,
            hasRumble: true,
            hasLightbar: false,
            hasBattery: true
        )
        XCTAssertFalse(rumbleOnly.hasLightbar)
        XCTAssertTrue(rumbleOnly.hasRumble)
    }

    func testHasLightbarParticipatesInEquality() {
        var withLight = ControllerCapabilities()
        withLight.hasLightbar = true
        XCTAssertNotEqual(withLight, ControllerCapabilities.none)
        var alsoWithLight = ControllerCapabilities()
        alsoWithLight.hasLightbar = true
        XCTAssertEqual(withLight, alsoWithLight)
    }
}
