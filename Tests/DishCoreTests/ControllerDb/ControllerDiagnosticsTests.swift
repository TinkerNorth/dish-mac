// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The levels below the wire: the expect check at attach, the issues that
/// apply to this Mac, the last write's verdict and the person's answers.
final class ControllerDiagnosticsTests: XCTestCase {

    // MARK: - Expect

    func testAHardwareFactThatBreaksItsExpectationIsAMismatchInTheContractsForm() {
        let mismatches = expectMismatches(
            ControllerExpect(endpointIn: true, endpointOut: true),
            observed: ObservedEndpoints(input: true, output: false)
        )
        XCTAssertEqual(mismatches, ["endpoints.out: expected true, found false"])
    }

    func testBothDirectionsAreComparedInOrder() {
        let mismatches = expectMismatches(
            ControllerExpect(endpointIn: false, endpointOut: false),
            observed: ObservedEndpoints(input: true, output: true)
        )
        XCTAssertEqual(mismatches, ["endpoints.in: expected false, found true", "endpoints.out: expected false, found true"])
    }

    func testAnUnknownExpectationIsNotCompared() {
        XCTAssertEqual(
            expectMismatches(ControllerExpect(endpointIn: nil, endpointOut: nil), observed: ObservedEndpoints(input: false, output: false)),
            []
        )
    }

    func testAFactThePathCannotSeeIsNotCompared() {
        XCTAssertEqual(
            expectMismatches(ControllerExpect(endpointIn: true, endpointOut: true), observed: ObservedEndpoints(input: nil, output: nil)),
            []
        )
    }

    func testHardwareThatMeetsItsExpectationHasNoMismatch() {
        XCTAssertEqual(
            expectMismatches(ControllerExpect(endpointIn: true, endpointOut: false), observed: ObservedEndpoints(
                input: true,
                output: false
            )),
            []
        )
    }

    // MARK: - Issues

    private let mac = IssueHost(model: "Mac14,2", osMajor: 26)

    func testAnIssueOnAnotherDeviceDoesNotApplyHere() {
        let thor = ControllerIssue(id: "thor", device: "AYN Thor", os: ["android": 15], transport: .usb)
        XCTAssertEqual(issuesApplying([thor], transport: .usb, host: mac), [])
    }

    func testAnIssueWithNoDeviceOnThePadsTransportApplies() {
        let anywhere = ControllerIssue(id: "usb", transport: .usb)
        XCTAssertEqual(issuesApplying([anywhere], transport: .usb, host: mac), [anywhere])
        XCTAssertEqual(issuesApplying([anywhere], transport: .bluetooth, host: mac), [], "another transport")
        XCTAssertEqual(issuesApplying([anywhere], transport: nil, host: mac), [], "a transport the pad does not say")
    }

    func testAnIssueOnEveryTransportAppliesWhateverThePadsIs() {
        let every = ControllerIssue(id: "all")
        XCTAssertEqual(issuesApplying([every], transport: .bluetooth, host: mac), [every])
        XCTAssertEqual(issuesApplying([every], transport: nil, host: mac), [every])
    }

    func testAnIssueOnThisMacAppliesAndOnlyOnThisMacOS() {
        let here = ControllerIssue(id: "here", device: "Mac14,2", os: ["macos": 26])
        XCTAssertEqual(issuesApplying([here], transport: .usb, host: mac), [here])
        XCTAssertEqual(issuesApplying([here], transport: .usb, host: IssueHost(model: "Mac14,2", osMajor: 27)), [])
        XCTAssertEqual(issuesApplying([here], transport: .usb, host: IssueHost(model: "Mac15,1", osMajor: 26)), [])
    }

    func testAnIssueNamingOnlyAnotherPlatformsOSDoesNotApplyHere() {
        XCTAssertEqual(issuesApplying([ControllerIssue(id: "a", os: ["android": 15])], transport: .usb, host: mac), [])
    }

    // MARK: - The last write

    func testAWriteIOKitTookIsOkWithNoError() {
        let verdict = DirectWriteVerdict(route: .setReport, reportId: 0x80, status: 0, atMs: 5)
        XCTAssertTrue(verdict.ok)
        XCTAssertNil(verdict.error)
        XCTAssertEqual(verdict.reportId, 0x80)
        XCTAssertEqual(verdict.atMs, 5)
    }

    func testARefusedWriteCarriesIOKitsName() {
        let verdict = DirectWriteVerdict(route: .interruptOut, reportId: 0, status: Int32(bitPattern: 0xE000_02ED), atMs: 5)
        XCTAssertFalse(verdict.ok)
        XCTAssertEqual(verdict.error, "kIOReturnNotResponding")
    }

    func testACodeWithNoNameIsWrittenInHex() {
        XCTAssertEqual(ioReturnName(Int32(bitPattern: 0xE000_1234)), "0xe0001234")
        XCTAssertEqual(ioReturnName(Int32(bitPattern: 0xE000_4051)), "kIOUSBPipeStalled")
    }

    // MARK: - Outcomes

    func testAnAnswerIsAppendedAfterTheOthers() {
        let first = TestOutcome(test: .rumbleWeak, result: .worked, atMs: 1)
        let second = TestOutcome(test: .tone, result: .didNotWork, atMs: 2)
        XCTAssertEqual(appendingOutcome(appendingOutcome([], first), second), [first, second])
    }

    func testTheListKeepsTheNewestTwenty() {
        let answers = (1 ... 25).map { TestOutcome(test: .stickDrift, result: .worked, atMs: Int64($0)) }
        let kept = answers.reduce([TestOutcome]()) { appendingOutcome($0, $1) }
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept.first?.atMs, 6)
        XCTAssertEqual(kept.last?.atMs, 25)
    }

    func testTheTestIdsAreTheBundlesWords() {
        XCTAssertEqual(
            InspectorTest.allCases.map(\.rawValue),
            ["rumble.weak", "rumble.strong", "rumble.both", "tone", "mic", "stick.drift", "stick.range"]
        )
        XCTAssertEqual(OutcomeResult.allCases.map(\.rawValue), ["worked", "didNotWork"])
    }
}
