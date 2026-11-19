// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The controller data's words: the standing in Settings and Diagnostics,
/// a pad's record on its card, the mail, and "Did it work?".
final class ControllerDbMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")
    private let words = L10n.app

    private func utc() throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: "UTC"))
    }

    private let strings = ControllerStrings(tables: [
        "en": [
            "controller.sony-dualsense.name": "DualSense Wireless Controller",
            "issue.mac-usb.title": "No rumble",
            "issue.mac-usb.body": "Rumble does not reach it.",
            "issue.untitled.title": "Only a title"
        ]
    ])

    // MARK: - The standing

    func testEachResultHasItsWord() {
        XCTAssertEqual(ControllerDbCheckResult.allCases.map { controllerDbResultText($0) }, [
            "Up to date", "Updated", words.offline, "The download did not verify", "Checks are off"
        ])
    }

    func testTheVersionSaysWhereItCameFrom() {
        XCTAssertEqual(controllerDbVersionText(ControllerDbStatus(activeVersion: 1, source: .bundled)), "Version 1, bundled with Dish")
        XCTAssertEqual(controllerDbVersionText(ControllerDbStatus(activeVersion: 3, source: .cache)), "Version 3, downloaded")
    }

    func testACheckIsRunningNeverRanOrRanAtATimeWithAResult() throws {
        var status = ControllerDbStatus()
        XCTAssertEqual(controllerDbCheckText(status), "Never checked")
        status.lastCheckAtMs = 1_763_586_251_000
        status.lastCheckResult = .upToDate
        let time = try eventTimeText(1_763_586_251_000, locale: english, timeZone: utc())
        XCTAssertEqual(try controllerDbCheckText(status, locale: english, timeZone: utc()), "Last check \(time): Up to date")
        status.checking = true
        XCTAssertEqual(controllerDbCheckText(status), "Checking…")
    }

    func testCheckNowWaitsWhileACheckRunsAndWithTheSwitchOff() {
        XCTAssertTrue(controllerDbRow(ControllerDbStatus(checksEnabled: true)).canCheck)
        XCTAssertFalse(controllerDbRow(ControllerDbStatus(checksEnabled: false)).canCheck)
        var running = ControllerDbStatus(checksEnabled: true)
        running.checking = true
        XCTAssertFalse(controllerDbRow(running).canCheck)
        XCTAssertFalse(controllerDbRow(ControllerDbStatus(checksEnabled: false)).checksEnabled)
    }

    func testDiagnosticsShowsBothVersionsAndTheLastCheck() {
        let lines = controllerDbLines(ControllerDbStatus(bundledVersion: 1, activeVersion: 2, source: .cache))
        XCTAssertEqual(lines.map(\.key), ["Bundled version", "Version in use", "Last check"])
        XCTAssertEqual(lines.map(\.value), ["1", "Version 2, downloaded", "Never checked"])
    }

    func testSettingsCarriesTheRow() {
        var facts = ShellFacts()
        facts.controllerDb = ControllerDbStatus(activeVersion: 1, checksEnabled: false)
        XCTAssertEqual(settingsPageState(facts: facts).controllerDb, controllerDbRow(facts.controllerDb))
    }

    // MARK: - A pad's record

    func testTheChipSpeaksTheCardsVocabulary() {
        XCTAssertEqual(verificationChip(.verified), "Verified")
        XCTAssertEqual(verificationChip(.imported), words.layoutGuessed)
        XCTAssertEqual(verificationChip(.guessed), words.layoutGuessed)
        XCTAssertEqual(verificationChip(.crowd), words.layoutGuessed)
        XCTAssertEqual(verificationChip(.flagged), "Flagged")
    }

    private func pad(direct: Bool, record: Bool = true, mismatches: [String] = [], write: DirectWriteVerdict? = nil) -> PadDiagnostics {
        var path = SlotInputPath(source: direct ? .direct : .standard, reason: .macOSReads)
        path.expectMismatches = mismatches
        path.lastWrite = write
        var pad = PadDiagnostics(slot: ControllerSlot(id: "pad", name: "DualSense"), wire: nil, inputPath: path)
        pad.record = record ? ControllerRecord(id: "sony-dualsense", familyId: "dualsense", verification: .imported) : nil
        return pad
    }

    func testARecordShowsItsIdAndItsName() {
        let lines = recordLines(pad(direct: false), strings: strings)
        XCTAssertEqual(lines.map(\.key), ["Record", "Listed as"])
        XCTAssertEqual(lines.map(\.value), ["sony-dualsense", "DualSense Wireless Controller"])
    }

    func testARecordWithNoNameShowsItsIdAlone() {
        XCTAssertEqual(recordLines(pad(direct: false), strings: ControllerStrings(tables: [:])).map(\.key), ["Record"])
    }

    func testAPadWithNoRecordShowsNoRecordLines() {
        XCTAssertEqual(recordLines(pad(direct: false, record: false), strings: strings), [])
    }

    func testADirectPadShowsItsHardwareCheckAndItsLastWrite() {
        let lines = recordLines(pad(direct: true), strings: strings)
        XCTAssertEqual(lines.map(\.key), ["Record", "Listed as", "Hardware check", "Last write"])
        XCTAssertEqual(lines.map(\.value).suffix(2), ["As expected", "None yet"])
        let broken = recordLines(pad(direct: true, mismatches: ["endpoints.out: expected true, found false"]), strings: strings)
        XCTAssertEqual(broken[2].value, "endpoints.out: expected true, found false")
    }

    func testADirectPadWithNoRecordStillShowsItsLastWrite() {
        XCTAssertEqual(recordLines(pad(direct: true, record: false), strings: strings).map(\.key), ["Last write"])
    }

    func testAWriteSaysItsReportRouteTimeAndAnswer() throws {
        let time = try eventTimeText(1_763_586_251_000, locale: english, timeZone: utc())
        let went = DirectWriteVerdict(route: .setReport, reportId: 0x80, status: 0, atMs: 1_763_586_251_000)
        XCTAssertEqual(try lastWriteText(went, locale: english, timeZone: utc()), "Report 0x80 via SET_REPORT went through at \(time)")
        let refused = DirectWriteVerdict(route: .interruptOut, reportId: 0, status: Int32(bitPattern: 0xE000_02ED), atMs: 1_763_586_251_000)
        XCTAssertEqual(
            try lastWriteText(refused, locale: english, timeZone: utc()),
            "Report 0x00 via interrupt OUT was refused at \(time): kIOReturnNotResponding"
        )
    }

    func testAnIssueShowsItsTitleAndBodyOrWhatTheDataHas() {
        XCTAssertEqual(issueText(ControllerIssue(id: "mac-usb"), strings: strings), "No rumble: Rumble does not reach it.")
        XCTAssertEqual(issueText(ControllerIssue(id: "untitled"), strings: strings), "Only a title")
        XCTAssertEqual(issueText(ControllerIssue(id: "ghost"), strings: strings), "ghost")
        var withIssue = pad(direct: false)
        withIssue.issues = [ControllerIssue(id: "mac-usb")]
        XCTAssertEqual(
            recordLines(withIssue, strings: strings).last,
            FactLine(key: "Known issue", value: "No rumble: Rumble does not reach it.")
        )
    }

    func testTheCardWearsTheRecordsChipUnlessItsLayoutIsGuessed() {
        XCTAssertEqual(padCard(pad(direct: false), strings: strings).chip, words.layoutGuessed, "imported reads as guessed")
        var verified = pad(direct: false)
        verified.record = ControllerRecord(id: "x", familyId: "hid", verification: .verified)
        XCTAssertEqual(padCard(verified).chip, "Verified")
        XCTAssertNil(padCard(pad(direct: false, record: false)).chip)
    }

    // MARK: - The mail

    func testTheMailGoesToSupportWithTheContractsSubjectAndTheSummary() throws {
        var facts = ShellFacts()
        facts.diagnostics = DiagnosticsSnapshot(pads: [pad(direct: false)])
        let page = try diagnosticsPageState(
            facts: facts,
            mail: DiagnosticsMailFacts(version: "1.4.0", model: "Mac14,2"),
            locale: english,
            timeZone: utc()
        )
        XCTAssertEqual(page.mail.recipient, "support@tinkernorth.com")
        XCTAssertEqual(page.mail.subject, "Dish diagnostics: Dish for macOS 1.4.0 on Mac14,2")
        XCTAssertTrue(page.mail.body.hasPrefix("Controller database\nController database\n  Bundled version: 0"))
        XCTAssertTrue(page.mail.body.contains("DualSense\n  Connection:"))
        XCTAssertTrue(page.mail.body.hasSuffix("\n\n" + words.diagnosticsAttachmentSentence))
    }

    func testAnEmptySectionSaysWhyInTheSummary() throws {
        let page = try diagnosticsPageState(facts: ShellFacts(), locale: english, timeZone: utc())
        XCTAssertTrue(diagnosticsSummaryText(page).contains("Hosts\n" + words.noSatellitesYet))
    }

    // MARK: - Did it work?

    func testEachTestHasItsName() {
        XCTAssertEqual(InspectorTest.allCases.map { inspectorTestText($0) }, [
            buzzMotorText(.weak), buzzMotorText(.strong), buzzMotorText(.both), "Test tone", words.microphone, "Drift test", "Range test"
        ])
    }

    func testBeforeAnyTestTheSectionSaysWhatToDo() {
        let state = outcomesState(slotId: "pad", outcomes: PadOutcomes(), stickTestRunning: false)
        XCTAssertNil(state.question)
        XCTAssertEqual(state.answers, [])
        XCTAssertEqual(state.hint, words.outcomesHint)
    }

    func testATestThatRanAsksAndTheAnswersShowNewestFirst() {
        let outcomes = PadOutcomes(
            asking: ["pad": .tone],
            answers: ["pad": [
                TestOutcome(test: .rumbleWeak, result: .worked, atMs: 1),
                TestOutcome(test: .microphone, result: .didNotWork, atMs: 2)
            ]]
        )
        let state = outcomesState(slotId: "pad", outcomes: outcomes, stickTestRunning: false)
        XCTAssertEqual(state.question, "Test tone: did it work?")
        XCTAssertEqual(state.answers, ["\(words.microphone) · It didn't work", "\(buzzMotorText(.weak)) · It worked"])
        XCTAssertNil(state.hint)
    }

    func testAStickTestAsksOnlyOnceItHasFinished() {
        let outcomes = PadOutcomes(asking: ["pad": .stickDrift])
        XCTAssertNil(outcomesState(slotId: "pad", outcomes: outcomes, stickTestRunning: true).question)
        XCTAssertEqual(outcomesState(slotId: "pad", outcomes: outcomes, stickTestRunning: false).question, "Drift test: did it work?")
        let rumble = PadOutcomes(asking: ["pad": .rumbleBoth])
        XCTAssertNotNil(outcomesState(slotId: "pad", outcomes: rumble, stickTestRunning: true).question, "another test asks at once")
    }

    func testAnotherPadsQuestionIsNotThisOnes() {
        XCTAssertNil(outcomesState(slotId: "other", outcomes: PadOutcomes(asking: ["pad": .tone]), stickTestRunning: false).question)
    }
}
