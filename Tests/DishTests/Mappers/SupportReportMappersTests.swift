// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// "Report a problem" and "Ask a question": the categories in the person's
/// words, the controller suggested and picked, what the file holds, and the
/// mail with their words first.
final class SupportReportMappersTests: XCTestCase {

    private let words = L10n.app
    private let english = Locale(identifier: "en_US")
    private let mailFacts = DiagnosticsMailFacts(version: "1.4.0", model: "Mac14,2")

    private func utc() throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: "UTC"))
    }

    private func pad(_ id: String, _ name: String) -> PadDiagnostics {
        PadDiagnostics(slot: ControllerSlot(id: id, name: name), wire: nil)
    }

    private func facts(pads: [PadDiagnostics] = [], preparing: Bool = false) -> ShellFacts {
        var facts = ShellFacts()
        facts.diagnostics = DiagnosticsSnapshot(pads: pads)
        facts.reportPreparation = preparing ? .loadingFresh : ReportPreparationState.idle.toSuccess(ReportPreparation(
            snapshots: [:],
            conditions: .unknown
        ))
        return facts
    }

    private func state(_ form: SupportReportForm, _ facts: ShellFacts) throws -> SupportReportPageState {
        try supportReportPageState(form: form, facts: facts, mail: mailFacts, locale: english, timeZone: utc())
    }

    func testEveryCategoryHasItsWords() {
        XCTAssertEqual(SupportReportCategory.allCases.map { reportCategoryText($0) }, [
            "Controller not recognised", "No rumble or feedback", "Connection or latency", "Controller audio", "Something else",
            "A question"
        ])
    }

    func testThePickerOffersEveryCategory() throws {
        let state = try state(SupportReportForm(category: .other), facts())
        XCTAssertEqual(state.categories.map(\.value), SupportReportCategory.allCases)
    }

    func testTheFirstAttachedPadIsSuggested() throws {
        let state = try state(SupportReportForm(category: .noFeedback), facts(pads: [pad("a", "DualSense"), pad("b", "Xbox")]))
        XCTAssertEqual(state.controllerSelection, .slot("a"))
        XCTAssertEqual(state.draft.slotId, "a")
        XCTAssertEqual(state.controllers.map(\.label), ["DualSense", "Xbox", words.notAboutAController])
    }

    func testWithNoPadTheSuggestionIsNone() throws {
        let state = try state(SupportReportForm(category: .question), facts())
        XCTAssertEqual(state.controllerSelection, .none)
        XCTAssertNil(state.draft.slotId)
        XCTAssertEqual(state.controllers.map(\.value), [.none])
    }

    func testAPickReplacesTheSuggestion() throws {
        var form = SupportReportForm(category: .noFeedback)
        form.controller = .slot("b")
        XCTAssertEqual(try state(form, facts(pads: [pad("a", "DualSense"), pad("b", "Xbox")])).draft.slotId, "b")
        form.controller = .none
        XCTAssertNil(try state(form, facts(pads: [pad("a", "DualSense")])).draft.slotId)
    }

    func testAPickedPadThatLeftIsNone() {
        XCTAssertEqual(reportControllerSelection(.slot("gone"), pads: [pad("a", "DualSense")]), .none)
    }

    func testTheListSaysWhatTheFileHoldsAndNeverHolds() throws {
        let state = try state(SupportReportForm(category: .other), facts())
        XCTAssertEqual(state.holds.count, 5)
        XCTAssertTrue(state.holds.allSatisfy { $0.hasPrefix("• ") })
        XCTAssertEqual(state.never, words.reportNeverHolds)
    }

    func testWhileTheHostsAreAskedNothingCanContinue() throws {
        let state = try state(SupportReportForm(category: .other), facts(preparing: true))
        XCTAssertFalse(state.canContinue)
        XCTAssertEqual(state.preparing, words.askingHosts)
    }

    func testOnceTheyAnsweredThePersonCanContinue() throws {
        let state = try state(SupportReportForm(category: .other), facts())
        XCTAssertTrue(state.canContinue)
        XCTAssertNil(state.preparing)
    }

    func testTheMailPutsThePersonsWordsFirstAndNamesTheCategory() throws {
        var form = SupportReportForm(category: .noFeedback)
        form.text = "  Returnal never rumbles.  "
        let mail = try state(form, facts()).mail
        XCTAssertEqual(mail.recipient, "support@tinkernorth.com")
        XCTAssertEqual(mail.subject, "Dish support: No rumble or feedback · Dish for macOS 1.4.0 on Mac14,2")
        XCTAssertTrue(mail.body.hasPrefix("Returnal never rumbles.\n\nController database\n"))
        XCTAssertTrue(mail.body.hasSuffix("\n\n" + words.diagnosticsAttachmentSentence))
    }

    func testWithNoWordsTheMailStartsWithTheSummary() throws {
        let mail = try state(SupportReportForm(category: .question), facts()).mail
        XCTAssertTrue(mail.body.hasPrefix("Controller database\n"))
        XCTAssertTrue(mail.subject.hasPrefix("Dish support: A question · "))
    }

    func testTheDraftCarriesTheCategoryAndTheWordsAsTyped() throws {
        var form = SupportReportForm(category: .connection)
        form.text = "Lag"
        XCTAssertEqual(try state(form, facts()).draft, SupportReportDraft(category: .connection, text: "Lag", slotId: nil))
    }

    func testThePreviewButtonSaysWhatItWillDo() {
        XCTAssertEqual(previewToggleText(showing: false), words.previewFile)
        XCTAssertEqual(previewToggleText(showing: true), words.hideFile)
    }
}
