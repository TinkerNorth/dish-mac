// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// The controller a report concerns, as the page's picker holds it: the
/// pad the page suggests until the person picks, one pad, or none.
enum ReportControllerChoice: Hashable {
    case suggested
    case slot(String)
    case none
}

/// What the person has filled in so far; the page keeps it, the mapper reads it.
struct SupportReportForm: Equatable {
    var category: SupportReportCategory
    var text = ""
    var controller = ReportControllerChoice.suggested
}

struct ReportOption<Value: Hashable>: Equatable, Identifiable {
    let value: Value
    let label: String

    var id: Value {
        value
    }
}

/// "Report a problem" and "Ask a question": one page, the category picked,
/// the person's words, the controller it concerns, what the file will hold
/// and what it never holds, then Preview file and Continue in Mail.
struct SupportReportPageState: Equatable {
    let intro: String
    let categoryLabel: String
    let categories: [ReportOption<SupportReportCategory>]
    let textLabel: String
    let controllerLabel: String
    let controllers: [ReportOption<ReportControllerChoice>]
    /// The picker's selection: the suggestion resolved to a pad or none.
    let controllerSelection: ReportControllerChoice
    let holdsTitle: String
    let holds: [String]
    let never: String
    /// Shown while the hosts are asked; nil once they answered.
    let preparing: String?
    let canContinue: Bool
    let continueLabel: String
    /// What the model writes into the file.
    let draft: SupportReportDraft
    /// The mail the person's own app opens.
    let mail: DiagnosticsMailState
}

func reportCategoryText(_ category: SupportReportCategory, words: L10n = .app) -> String {
    switch category {
    case .notRecognised: words.categoryNotRecognised
    case .noFeedback: words.categoryNoFeedback
    case .connection: words.categoryConnection
    case .audio: words.controllerAudio
    case .other: words.categoryOther
    case .question: words.categoryQuestion
    }
}

/// The suggestion is the first attached pad, so a report about the one pad
/// on the desk names it without a pick; with no pad, it is none.
func reportControllerSelection(_ choice: ReportControllerChoice, pads: [PadDiagnostics]) -> ReportControllerChoice {
    switch choice {
    case .suggested: pads.first.map { .slot($0.slot.id) } ?? .none
    case let .slot(slotId): pads.contains { $0.slot.id == slotId } ? .slot(slotId) : .none
    case .none: .none
    }
}

func reportControllerOptions(_ pads: [PadDiagnostics], words: L10n = .app) -> [ReportOption<ReportControllerChoice>] {
    pads.map { ReportOption(value: .slot($0.slot.id), label: $0.slot.name) } + [ReportOption(
        value: .none,
        label: words.notAboutAController
    )]
}

/// Each line of the list, as a bullet.
func reportHolds(words: L10n = .app) -> [String] {
    [words.holdsYourWords, words.holdsThisMac, words.holdsControllers, words.holdsHosts, words.holdsLogAndCapture].map { "• \($0)" }
}

/// The mail: the person's words first, then the Diagnostics summary with
/// its hosts aliased and the sentence on the file; the subject names the category in their language.
func supportReportMail(
    _ form: SupportReportForm,
    summary: String,
    facts: DiagnosticsMailFacts,
    words: L10n = .app
) -> DiagnosticsMailState {
    let typed = reportText(form.text)
    let closing = summary + "\n\n" + words.diagnosticsAttachmentSentence
    return DiagnosticsMailState(
        recipient: DiagnosticsBundleFormat.recipient,
        subject: supportMailSubject(category: reportCategoryText(form.category, words: words), version: facts.version, model: facts.model),
        body: typed.isEmpty ? closing : typed + "\n\n" + closing
    )
}

/// The mail as one text for the clipboard when no mail app takes it: the
/// subject, then the body with the person's words first.
func supportReportMailText(_ mail: DiagnosticsMailState) -> String {
    mail.subject + "\n\n" + mail.body
}

/// What the page says when no mail app took the message: where the file
/// went, or that it was not saved, and that the message waits on the
/// clipboard for an email to support.
func noMailNote(savedAt file: URL?, recipient: String, words: L10n = .app) -> String {
    guard let file else { return paragraph(words.noMailApp, words.fileNotSaved, words.messageOnTheClipboard(recipient)) }
    return paragraph(words.noMailApp, words.fileSavedAt(file.path), words.messageOnTheClipboard(recipient), words.attachTheFile)
}

func supportReportPageState(
    form: SupportReportForm,
    facts: ShellFacts,
    mail: DiagnosticsMailFacts,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> SupportReportPageState {
    let pads = facts.diagnostics.pads
    let selection = reportControllerSelection(form.controller, pads: pads)
    let preparing = facts.reportPreparation.isLoading
    let page = diagnosticsPageState(facts: facts, locale: locale, timeZone: timeZone, words: words)
    let summary = diagnosticsMailSummaryText(page, hosts: facts.diagnostics.hosts, words: words)
    let slotId: String? = if case let .slot(id) = selection { id } else { nil }
    return SupportReportPageState(
        intro: words.supportReportDetail,
        categoryLabel: words.reportCategory,
        categories: SupportReportCategory.allCases.map { ReportOption(value: $0, label: reportCategoryText($0, words: words)) },
        textLabel: words.whatHappened,
        controllerLabel: words.reportController,
        controllers: reportControllerOptions(pads, words: words),
        controllerSelection: selection,
        holdsTitle: words.theFileWillHold,
        holds: reportHolds(words: words),
        never: words.reportNeverHolds,
        preparing: preparing ? words.askingHosts : nil,
        canContinue: !preparing,
        continueLabel: words.continueInMail,
        draft: SupportReportDraft(category: form.category, text: form.text, slotId: slotId),
        mail: supportReportMail(form, summary: summary, facts: mail, words: words)
    )
}

func previewToggleText(showing: Bool, words: L10n = .app) -> String {
    showing ? words.hideFile : words.previewFile
}
