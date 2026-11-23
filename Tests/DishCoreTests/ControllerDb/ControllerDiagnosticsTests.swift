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
        let thor = ControllerIssue(id: "thor", device: "AYN Thor", os: ["android": 15], transport: .usb, status: "open")
        XCTAssertEqual(issuesApplying([thor], transport: .usb, host: mac), [])
    }

    func testAnIssueWithNoDeviceOnThePadsTransportApplies() {
        let anywhere = ControllerIssue(id: "usb", transport: .usb, status: "open")
        XCTAssertEqual(issuesApplying([anywhere], transport: .usb, host: mac), [anywhere])
        XCTAssertEqual(issuesApplying([anywhere], transport: .bluetooth, host: mac), [], "another transport")
        XCTAssertEqual(issuesApplying([anywhere], transport: nil, host: mac), [], "a transport the pad does not say")
    }

    func testAnIssueOnEveryTransportAppliesWhateverThePadsIs() {
        let every = ControllerIssue(id: "all", status: "open")
        XCTAssertEqual(issuesApplying([every], transport: .bluetooth, host: mac), [every])
        XCTAssertEqual(issuesApplying([every], transport: nil, host: mac), [every])
    }

    func testAnIssueOnThisMacAppliesAndOnlyOnThisMacOS() {
        let here = ControllerIssue(id: "here", device: "Mac14,2", os: ["macos": 26], status: "open")
        XCTAssertEqual(issuesApplying([here], transport: .usb, host: mac), [here])
        XCTAssertEqual(issuesApplying([here], transport: .usb, host: IssueHost(model: "Mac14,2", osMajor: 27)), [])
        XCTAssertEqual(issuesApplying([here], transport: .usb, host: IssueHost(model: "Mac15,1", osMajor: 26)), [])
    }

    func testAnIssueNamingOnlyAnotherPlatformsOSDoesNotApplyHere() {
        XCTAssertEqual(issuesApplying([ControllerIssue(id: "a", os: ["android": 15], status: "open")], transport: .usb, host: mac), [])
    }

    func testAnIssueShowsOnlyWhileItIsOpen() {
        let closed = ControllerIssue(id: "fixed", status: "fixed")
        let unstated = ControllerIssue(id: "unstated")
        XCTAssertEqual(issuesApplying([closed, unstated], transport: .usb, host: mac), [])
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
            [
                "rumble.weak", "rumble.strong", "rumble.both",
                "triggerRumble.left", "triggerRumble.right", "triggerRumble.both",
                "lightbar.cycle", "playerLeds.cycle", "trigger.pulse",
                "tone.play", "haptics.play", "mic.level", "stick.drift", "stick.range"
            ]
        )
        XCTAssertEqual(OutcomeResult.allCases.map(\.rawValue), ["worked", "didNotWork"])
    }

    /// The contract's list against the Mac's: the lamp is the one item no
    /// Mac path carries (Tests/PARITY.md says why).
    func testTheMacRunsEveryTestTheContractNamesButTheLamps() {
        let contract = [
            "rumble.weak", "rumble.strong", "rumble.both", "triggerRumble.left", "triggerRumble.right", "triggerRumble.both",
            "lightbar.cycle", "playerLeds.cycle", "trigger.pulse", "lamp.on", "lamp.pulse", "tone.play", "haptics.play",
            "mic.level", "stick.drift", "stick.range"
        ]
        let mac = Set(InspectorTest.allCases.map(\.rawValue))
        XCTAssertEqual(contract.filter { !mac.contains($0) }, ["lamp.on", "lamp.pulse"])
        XCTAssertTrue(mac.isSubset(of: contract))
    }

    // MARK: - One answer per run

    func testATestAsksOnlyOnceItHasEnded() {
        var ledger = PadTestLedger()
        ledger.started(.lightbarCycle)
        XCTAssertEqual(ledger.running, .lightbarCycle)
        XCTAssertNil(ledger.asking)
        ledger.ended(.lightbarCycle, atMs: 1200)
        XCTAssertNil(ledger.running)
        XCTAssertEqual(ledger.asking, EndedTest(test: .lightbarCycle, atMs: 1200))
    }

    func testTheAnswerCarriesTheTimeTheTestEnded() {
        var ledger = PadTestLedger()
        ledger.started(.triggerPulse)
        ledger.ended(.triggerPulse, atMs: 2000)
        ledger.answered(worked: false)
        XCTAssertNil(ledger.asking)
        XCTAssertEqual(ledger.answers, [TestOutcome(test: .triggerPulse, result: .didNotWork, atMs: 2000)])
    }

    func testANewRunReplacesAQuestionStillUnanswered() {
        var ledger = PadTestLedger()
        ledger.started(.rumbleWeak)
        ledger.ended(.rumbleWeak, atMs: 400)
        ledger.started(.tone)
        XCTAssertNil(ledger.asking, "the new run's question waits for its own end")
        ledger.ended(.tone, atMs: 900)
        ledger.answered(worked: true)
        XCTAssertEqual(ledger.answers, [TestOutcome(test: .tone, result: .worked, atMs: 900)])
    }

    func testTheEndOfARunAnotherRunReplacedAsksNothing() {
        var ledger = PadTestLedger()
        ledger.started(.rumbleStrong)
        ledger.started(.playerLedsCycle)
        ledger.ended(.rumbleStrong, atMs: 400)
        XCTAssertEqual(ledger.running, .playerLedsCycle)
        XCTAssertNil(ledger.asking)
    }

    func testAnAnswerWithNoQuestionWaitingIsNothing() {
        var ledger = PadTestLedger()
        ledger.answered(worked: true)
        ledger.started(.microphone)
        ledger.answered(worked: true)
        XCTAssertEqual(ledger, {
            var running = PadTestLedger()
            running.started(.microphone)
            return running
        }())
        XCTAssertEqual(ledger.answers, [])
    }

    func testTheLedgerKeepsTheNewestTwentyAnswers() {
        var ledger = PadTestLedger()
        for at in 1 ... 22 {
            ledger.started(.stickDrift)
            ledger.ended(.stickDrift, atMs: Int64(at))
            ledger.answered(worked: true)
        }
        XCTAssertEqual(ledger.answers.map(\.atMs), Array(3 ... 22).map(Int64.init))
    }
}
