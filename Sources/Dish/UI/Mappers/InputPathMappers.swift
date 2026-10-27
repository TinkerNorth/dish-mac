// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// What a Diagnostics card's Connection line says: GameController, or the
/// HID reports Dish reads itself.
func connectionText(_ path: SlotInputPath?, words: L10n = .app) -> String {
    path?.source == .direct ? words.hidReports : words.gameControllerFramework
}

/// The path, its one reason, and a Direct pad's report rate; nothing for a
/// pad the paths have no facts for yet.
func inputPathLines(_ path: SlotInputPath?, words: L10n = .app) -> [FactLine] {
    guard let path else { return [] }
    let opening = [
        FactLine(key: words.inputPath, value: inputSourceText(path.source, words: words)),
        FactLine(key: words.pathReason, value: inputSourceReasonText(path.reason, words: words))
    ]
    let rate = path.rawReportHz.map { [FactLine(key: words.reportsFromThePad, value: words.hertz($0))] } ?? []
    return opening + rate
}

func inputSourceText(_ source: InputSource, words: L10n = .app) -> String {
    switch source {
    case .standard: words.standardPath
    case .direct: words.directPath
    }
}

func inputSourceReasonText(_ reason: InputSourceReason, words: L10n = .app) -> String {
    switch reason {
    case .directByModel: words.reasonDirectByModel
    case .macOSCannotRead: words.reasonMacOSCannotRead
    case .macOSReads: words.reasonMacOSReads
    case .userPicked: words.reasonUserPicked
    }
}

func checkVerdictText(_ verdict: CheckVerdict, words: L10n = .app) -> String {
    switch verdict {
    case .standardWorks: words.verdictStandardWorks
    case .dishReadsIt: words.verdictDishReadsIt
    case .noDecoder: words.verdictNoDecoder
    case .nothingAtAll: words.verdictNothingAtAll
    }
}

/// An input-path line of the flight recorder; a line that lost its note
/// reads as its pad alone.
func pathEventText(_ event: DiagnosticsEvent, words: L10n = .app) -> String {
    switch event.path {
    case let .chosen(source, reason):
        words.eventPadPathChosen(event.subject, inputSourceText(source, words: words), inputSourceReasonText(reason, words: words))
    case let .verdict(verdict): words.eventPadCheckConcluded(event.subject, checkVerdictText(verdict, words: words))
    case .keepsDisconnecting: words.eventPadKeepsDisconnecting(event.subject)
    case nil: event.subject
    }
}
