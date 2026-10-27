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

/// The path, its one reason, a Direct pad's report rate, the pad's player
/// number and a pad that keeps dropping; nothing for a pad the paths have
/// no facts for yet.
func inputPathLines(_ path: SlotInputPath?, words: L10n = .app) -> [FactLine] {
    guard let path else { return [] }
    let opening = [
        FactLine(key: words.inputPath, value: inputSourceText(path.source, words: words)),
        FactLine(key: words.pathReason, value: inputSourceReasonText(path.reason, words: words))
    ]
    let rate = path.rawReportHz.map { FactLine(key: words.reportsFromThePad, value: words.hertz($0)) }
    let player = path.playerNumber.map { FactLine(key: words.playerWord, value: "\($0)") }
    let drops = path.keepsDisconnecting ? FactLine(key: words.disconnects, value: words.padKeepsDropping) : nil
    return opening + [rate, player, drops].compactMap { $0 }
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
    case .dishCouldNotRead: words.reasonDishCouldNotRead
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

// MARK: - A card's path

/// What a controller card, its Home node and the inspector draw of a pad's
/// input path: the path and its reason, the player number, the prompt
/// while the path is unproven, the "Not responding?" check, and the picker
/// where both paths work.
struct PadPathState: Equatable {
    /// "Input path", the inspector's section header.
    let title: String
    /// "Standard" or "Direct".
    let path: String
    let reason: String
    /// "Player 1", once the pad has a number.
    let player: String?
    /// Until a real change proves the path; a running check asks for A instead.
    let prompt: String?
    let check: PadCheckState
    /// The "Input path" control, only where the other path works now (R6).
    let picker: PathPickerState?
}

/// The check's line: the link while none runs, the countdown while one
/// does, and the last one's finding with its one action.
struct PadCheckState: Equatable {
    let link: String?
    let countdown: String?
    let verdict: String?
    let action: CheckActionState?
}

/// A finding's one way on.
enum CheckActionState: Equatable {
    case useDirect(String)
    case helpSupport(String)
    case hint(String)
}

struct PathPickerState: Equatable {
    let title: String
    let options: [PathOptionState]
    let selected: InputSource
}

struct PathOptionState: Equatable, Identifiable {
    let id: InputSource
    let label: String
}

func padPathState(_ path: SlotInputPath?, words: L10n = .app) -> PadPathState? {
    guard let path else { return nil }
    let asksForA = if case .running = path.check { true } else { false }
    return PadPathState(
        title: words.inputPath,
        path: inputSourceText(path.source, words: words),
        reason: inputSourceReasonText(path.reason, words: words),
        player: path.playerNumber.map(words.playerNumber),
        prompt: path.proven || asksForA ? nil : words.pressAnyButtonOnThisController,
        check: padCheckState(path.check, words: words),
        picker: pathPicker(path, words: words)
    )
}

func padCheckState(_ phase: InputCheckPhase, words: L10n = .app) -> PadCheckState {
    switch phase {
    case .idle:
        PadCheckState(link: words.notResponding, countdown: nil, verdict: nil, action: nil)
    case let .running(secondsLeft):
        PadCheckState(link: nil, countdown: words.pressANow(secondsLeft), verdict: nil, action: nil)
    case let .concluded(verdict, offer):
        PadCheckState(
            link: words.notResponding,
            countdown: nil,
            verdict: checkFindingText(verdict, words: words),
            action: checkAction(offer, words: words)
        )
    }
}

/// A check's finding as the card says it; the flight recorder has its own
/// shorter words (`checkVerdictText`).
func checkFindingText(_ verdict: CheckVerdict, words: L10n = .app) -> String {
    switch verdict {
    case .standardWorks: words.checkRespondsThroughMacOS
    case .dishReadsIt: words.checkRespondsReadDirectly
    case .noDecoder: words.checkNothingDishCanRead
    case .nothingAtAll: words.checkNothingArrived
    }
}

func checkAction(_ offer: CheckOffer, words: L10n = .app) -> CheckActionState? {
    switch offer {
    case .none: nil
    case .useDirect: .useDirect(words.useDirect)
    case .helpSupport: .helpSupport(words.helpSupportThisController)
    case .connectionHint: .hint(words.connectionHint)
    }
}

/// Both segments, the current one selected, while the engine offers the
/// other: never for the N64, whose only working path is Direct.
func pathPicker(_ path: SlotInputPath, words: L10n = .app) -> PathPickerState? {
    guard !path.picks.isEmpty else { return nil }
    let options = InputSource.allCases.map { PathOptionState(id: $0, label: inputSourceText($0, words: words)) }
    return PathPickerState(title: words.inputPath, options: options, selected: path.source)
}

/// Where "Help support this controller" goes. Diagnostics for now, whose
/// "Other input devices" cards carry the USB ID; the guided capture will
/// get a page of its own and this target moves to it.
func helpSupportPage(forSlot _: String) -> Page {
    .diagnostics
}

/// A Home node's path line: "Player 1 · Direct · Dish reads this model itself".
func padNodePathLine(_ state: PadPathState) -> String {
    ([state.player].compactMap { $0 } + [state.path, state.reason]).joined(separator: " · ")
}
