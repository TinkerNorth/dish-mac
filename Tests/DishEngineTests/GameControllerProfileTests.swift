// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// A pad GameController vends without the extended profile is adopted
/// through its physical profile. GameController's micro-gamepad snapshot
/// is such a pad (a d-pad, A, X and Menu, no extended profile), so the
/// bridge is driven through the framework itself, not a stand-in.
@MainActor
final class GameControllerProfileTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GCController.shouldMonitorBackgroundEvents = false
    }

    private func microPad() throws -> (GCController, GCMicroGamepad) {
        let controller = GCController.withMicroGamepad()
        XCTAssertNil(controller.extendedGamepad, "the snapshot carries no extended profile")
        return try (controller, XCTUnwrap(controller.microGamepad))
    }

    // MARK: - The framework's facts the tables lean on

    func testApplesElementNamesAreTheLiteralsTheCoreTablesUse() {
        let apple: [(String, String)] = [
            (GCInputButtonA, "Button A"), (GCInputButtonB, "Button B"), (GCInputButtonX, "Button X"), (GCInputButtonY, "Button Y"),
            (GCInputDirectionPad, "Direction Pad"), (GCInputLeftThumbstick, "Left Thumbstick"),
            (GCInputRightThumbstick, "Right Thumbstick"), (GCInputLeftShoulder, "Left Shoulder"),
            (GCInputRightShoulder, "Right Shoulder"), (GCInputLeftTrigger, "Left Trigger"), (GCInputRightTrigger, "Right Trigger"),
            (GCInputButtonMenu, "Button Menu"), (GCInputButtonOptions, "Button Options"), (GCInputButtonHome, "Button Home"),
            (GCInputButtonShare, "Button Share"), (GCInputLeftThumbstickButton, "Left Thumbstick Button"),
            (GCInputRightThumbstickButton, "Right Thumbstick Button")
        ]
        let tableNames = Set(ProfileLayout.of(.generic).buttons.flatMap(\.names) + ProfileLayout.of(.generic).directions.flatMap(\.names))
        for (constant, literal) in apple {
            XCTAssertEqual(constant, literal)
        }
        XCTAssertTrue(Set(apple.map(\.1)).subtracting(["Button Share"]).isSubset(of: tableNames), "every documented name has a row")
    }

    /// GCExtendedGamepad.h: "All face buttons ... must be arranged in the
    /// diamond pattern given below: Y on top, X left, B right, A at the
    /// bottom." So `buttonA` is the south button on every family, a
    /// Nintendo pad's included, and the profile files it as "Button A".
    func testButtonAIsTheSouthFaceButtonAndTheProfileFilesItAsButtonA() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        XCTAssertTrue(controller.physicalInputProfile.buttons[GCInputButtonA] === pad.buttonA)
        XCTAssertTrue(controller.physicalInputProfile.buttons[GCInputButtonB] === pad.buttonB)
        pad.buttonA.setValue(1)
        XCTAssertEqual(GameControllerInput.padSample(pad).pressed, [.faceA], "south is XUSB A")
    }

    func testTheFrameworksNintendoWordsMakeTheNintendoFamily() {
        let nintendo = [
            ("Switch Pro Controller", nil), ("Nintendo Switch Joy-Con (L/R)", nil), ("N64 Controller", nil),
            ("SNES Controller", nil), ("HID", "Nintendo"), ("NES Controller", "Nintendo")
        ] as [(String, String?)]
        for (category, vendor) in nintendo {
            XCTAssertEqual(namedPadFamily(productCategory: category, vendorName: vendor), .nintendo, category)
        }
        XCTAssertEqual(namedPadFamily(productCategory: "HID", vendorName: "8BitDo Pro 2"), .other)
        XCTAssertEqual(namedPadFamily(productCategory: "MFi", vendorName: nil), .other)
    }

    // MARK: - Adoption

    func testAPadWithoutAnExtendedProfileIsAdoptedThroughItsProfile() throws {
        let (controller, _) = try microPad()
        let input = GameControllerInput(connected: [controller])
        XCTAssertEqual(input.slots.count, 1)
        XCTAssertEqual(input.slots.first?.family, .other)
        XCTAssertEqual(input.slots.first?.capabilities.hasTouchpad, false)
        XCTAssertEqual(input.slots.first?.capabilities.hasBattery, true)
        XCTAssertTrue(controller.handlerQueue === input.inputQueue)
        XCTAssertNotNil(controller.physicalInputProfile.valueDidChangeHandler)
        XCTAssertTrue(input.monitorsBackgroundEvents)
    }

    func testTheElementsAreGroupedOneEntryPerElement() throws {
        let (controller, _) = try microPad()
        let groups = GameControllerInput.elementAliases(controller.physicalInputProfile)
        XCTAssertEqual(groups.count, controller.physicalInputProfile.elements.count, "the snapshot files each element once")
        XCTAssertTrue(groups.contains(["Direction Pad"]))
        let resolved = resolveProfile(.of(.generic), elements: groups)
        XCTAssertEqual(resolved.unclaimed, [], "a micro pad's every element has a row or is a part of one")
        XCTAssertTrue(GameControllerInput.profileCensus(controller.physicalInputProfile).contains("allDpads=1"))
    }

    func testTheProfileHandlerPublishesTheWholePadOnTheInputQueue() throws {
        let (controller, micro) = try microPad()
        let input = GameControllerInput(connected: [controller])
        let published = expectation(description: "a report left the processor")
        let seen = LockedBox<(report: GamepadReport, onMain: Bool)?>(nil)
        input.processor.reportSender = { _, report in
            seen.set((report, Thread.isMainThread))
            published.fulfill()
        }
        micro.dpad.setValueForXAxis(0, yAxis: 1)
        micro.buttonA.setValue(1)
        micro.buttonMenu.setValue(1)
        let call = ProfileCall(profile: controller.physicalInputProfile, element: micro.buttonA)
        input.inputQueue.async { call.fire() }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(seen.get()?.report.buttons, WireButton.dpadUp.bit | WireButton.faceA.bit | WireButton.start.bit)
        XCTAssertEqual(seen.get()?.onMain, false, "the hot path never waits on the main thread")
    }

    func testADisconnectClearsTheProfileHandler() throws {
        let input = GameControllerInput(connected: [])
        let (controller, _) = try microPad()
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: controller)
        spinUntil({ !input.slots.isEmpty }, message: "the connect adopts the pad")
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
        spinUntil({ input.slots.isEmpty }, message: "the disconnect drops it")
        XCTAssertNil(controller.physicalInputProfile.valueDidChangeHandler)
    }

    private func spinUntil(_ predicate: () -> Bool, message: String) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !predicate() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(predicate(), message)
    }

    // MARK: - The resolved inputs

    func testAnN64ResolvedAgainstAProfileReadsItsCButtonsAndItsFullTriggers() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        let profile = controller.physicalInputProfile
        let resolved = resolveProfile(.of(.n64), elements: GameControllerInput.elementAliases(profile))
        let inputs = GameControllerInput.profileInputs(resolved, profile: profile)
        pad.rightThumbstick.setValueForXAxis(0, yAxis: 1)
        pad.leftTrigger.setValue(0.3)
        pad.leftThumbstick.setValueForXAxis(1, yAxis: 0)
        let report = wireReport(from: GameControllerInput.profileSample(inputs))
        XCTAssertEqual(report.ry, 32767, "a C button filed as the right stick's up rails up")
        XCTAssertEqual(report.lt, 255, "Z held reads as fully pulled")
        XCTAssertEqual(report.lx, 32767)
        XCTAssertTrue(inputs.triggers.isEmpty, "the N64's triggers are read as held")
    }
}

/// Calls the profile's handler the way the framework does, from the queue
/// the pad was handed. The framework's objects are not `Sendable`; this test
/// owns them and touches them on one queue at a time.
private struct ProfileCall: @unchecked Sendable {
    let profile: GCPhysicalInputProfile
    let element: GCControllerElement

    func fire() {
        profile.valueDidChangeHandler?(profile, element)
    }
}
