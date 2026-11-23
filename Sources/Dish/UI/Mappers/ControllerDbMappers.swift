// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

// MARK: - The data's standing

func controllerDbResultText(_ result: ControllerDbCheckResult, words: L10n = .app) -> String {
    switch result {
    case .upToDate: words.upToDate
    case .updated: words.updated
    case .offline: words.offline
    case .invalid: words.downloadDidNotVerify
    case .off: words.checksAreOff
    }
}

/// "Version 3, downloaded".
func controllerDbVersionText(_ status: ControllerDbStatus, words: L10n = .app) -> String {
    switch status.source {
    case .bundled: words.controllerDbBundled(status.activeVersion)
    case .cache: words.controllerDbDownloaded(status.activeVersion)
    }
}

/// A check running, none yet, or the last one's time and result.
func controllerDbCheckText(
    _ status: ControllerDbStatus,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> String {
    if status.checking { return words.checking }
    guard let atMs = status.lastCheckAtMs, let result = status.lastCheckResult else { return words.neverChecked }
    return words.lastCheckAt(eventTimeText(atMs, locale: locale, timeZone: timeZone), controllerDbResultText(result, words: words))
}

/// Settings' controller database rows: the standing, the switch and Check now.
struct ControllerDbRowState: Equatable {
    let version: String
    let lastCheck: String
    let checksEnabled: Bool
    /// Check now waits while a check runs, and sends nothing with the switch off.
    let canCheck: Bool
}

func controllerDbRow(
    _ status: ControllerDbStatus,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> ControllerDbRowState {
    ControllerDbRowState(
        version: controllerDbVersionText(status, words: words),
        lastCheck: controllerDbCheckText(status, locale: locale, timeZone: timeZone, words: words),
        checksEnabled: status.checksEnabled,
        canCheck: status.checksEnabled && !status.checking
    )
}

/// Diagnostics' card for the data: both versions, where the one in force
/// came from, and the last check.
func controllerDbLines(
    _ status: ControllerDbStatus,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> [FactLine] {
    [
        FactLine(key: words.bundledVersion, value: String(status.bundledVersion)),
        FactLine(key: words.versionInUse, value: controllerDbVersionText(status, words: words)),
        FactLine(key: words.lastCheck, value: controllerDbCheckText(status, locale: locale, timeZone: timeZone, words: words))
    ]
}

// MARK: - A pad's record

/// The record's chip in the vocabulary the cards already use: verified, a
/// layout guessed for every unconfirmed state, flagged.
func verificationChip(_ verification: ControllerVerification, words: L10n = .app) -> String {
    switch verification {
    case .verified: words.verified
    case .imported, .crowd, .guessed: words.layoutGuessed
    case .flagged: words.flagged
    }
}

/// What the Direct path wrote last: the report, the route, the time and
/// IOKit's answer.
func lastWriteText(_ write: DirectWriteVerdict?, locale: Locale = .current, timeZone: TimeZone = .current, words: L10n = .app) -> String {
    guard let write else { return words.noneYet }
    let report = String(format: "0x%02x", UInt32(write.reportId))
    let route = writeRouteText(write.route, words: words)
    let time = eventTimeText(write.atMs, locale: locale, timeZone: timeZone)
    guard let error = write.error else { return words.writeWent(report, route, time) }
    return words.writeRefused(report, route, time, error)
}

func writeRouteText(_ route: ControllerOutputRoute, words: L10n = .app) -> String {
    switch route {
    case .interruptOut: words.interruptOut
    case .setReport: words.setReport
    }
}

/// The record's id and name, a Direct pad's hardware check and last write,
/// and each issue that applies here, its title and body from the data's
/// words in the app's language.
func recordLines(
    _ pad: PadDiagnostics,
    strings: ControllerStrings,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    words: L10n = .app
) -> [FactLine] {
    let direct = pad.inputPath?.source == .direct
    let identity = pad.record.map { record in
        [FactLine(key: words.record, value: record.id)]
            + (strings.controllerName(record.id, locale: words.language).map { [FactLine(key: words.listedAs, value: $0)] } ?? [])
    } ?? []
    let check = direct && pad
        .record != nil ? [FactLine(key: words.hardwareCheck, value: hardwareCheckText(pad.inputPath, words: words))] : []
    let write = direct ? [FactLine(
        key: words.lastWrite,
        value: lastWriteText(pad.inputPath?.lastWrite, locale: locale, timeZone: timeZone, words: words)
    )] : []
    let issues = pad.issues.map { issue in FactLine(key: words.knownIssue, value: issueText(issue, strings: strings, words: words)) }
    return identity + check + write + issues
}

func hardwareCheckText(_ path: SlotInputPath?, words: L10n = .app) -> String {
    let mismatches = path?.expectMismatches ?? []
    return mismatches.isEmpty ? words.asExpected : mismatches.joined(separator: "\n")
}

/// "Title: body", or the issue's id when the data has no words for it.
func issueText(_ issue: ControllerIssue, strings: ControllerStrings, words: L10n = .app) -> String {
    let title = strings.issueTitle(issue.id, locale: words.language) ?? issue.id
    guard let body = strings.issueBody(issue.id, locale: words.language) else { return title }
    return "\(title): \(body)"
}

// MARK: - The mail

/// The mail the person's own app opens: to support, the subject the
/// contract names, and the body the report page writes.
struct DiagnosticsMailState: Equatable {
    let recipient: String
    let subject: String
    let body: String
}

/// The page's cards as plain text: each card's title, then its lines.
func diagnosticsSummaryText(_ page: DiagnosticsPageState, words: L10n = .app) -> String {
    summaryText(page, hosts: page.hosts, words: words)
}

/// The summary the mail carries: each host titled by the alias the file
/// gives it, with no address and no host name, and every other mention of a
/// host's name or address replaced by that alias. The page keeps the names.
func diagnosticsMailSummaryText(_ page: DiagnosticsPageState, hosts: [HostDiagnostics], words: L10n = .app) -> String {
    let summary = summaryText(page, hosts: mailHostCards(page.hosts, words: words), words: words)
    return aliasingHostNames(summary, hostNames: hosts.map(diagnosticsHostNames))
}

private func summaryText(_ page: DiagnosticsPageState, hosts: DiagnosticsCards, words: L10n) -> String {
    let sections = [
        (words.controllerDatabase, DiagnosticsCards.cards([page.controllerDb])),
        (words.hosts, hosts),
        (words.controllers, page.pads)
    ]
    return sections.map { title, cards in summarySection(title, cards) }.joined(separator: "\n\n")
}

/// The host cards in the file's order, which is the page's.
private func mailHostCards(_ cards: DiagnosticsCards, words: L10n) -> DiagnosticsCards {
    guard case let .cards(hosts) = cards else { return cards }
    return .cards(hosts.enumerated().map { position, card in mailHostCard(card, alias: hostAlias(position), words: words) })
}

private func mailHostCard(_ card: DiagnosticsCardState, alias: String, words: L10n) -> DiagnosticsCardState {
    let identifying: Set<String> = [words.address, words.hostName]
    return DiagnosticsCardState(
        id: card.id,
        title: alias,
        dot: card.dot,
        chip: card.chip,
        lines: card.lines.filter { !identifying.contains($0.key) },
        inspects: card.inspects
    )
}

private func summarySection(_ title: String, _ cards: DiagnosticsCards) -> String {
    switch cards {
    case let .empty(note):
        return "\(title)\n\(note)"
    case let .cards(cards):
        let bodies = cards.map { card in ([card.title] + card.lines.map { "  \($0.key): \($0.value)" }).joined(separator: "\n") }
        return ([title] + bodies).joined(separator: "\n")
    }
}

// MARK: - Did it work?

func inspectorTestText(_ test: InspectorTest, words: L10n = .app) -> String {
    switch test {
    case .rumbleWeak: words.rumbleWeakTest
    case .rumbleStrong: words.rumbleStrongTest
    case .rumbleBoth: words.rumbleBothTest
    case .triggerRumbleLeft: words.triggerRumbleLeftTest
    case .triggerRumbleRight: words.triggerRumbleRightTest
    case .triggerRumbleBoth: words.triggerRumbleBothTest
    case .lightbarCycle: words.lightbarCycleTest
    case .playerLedsCycle: words.playerLedsCycleTest
    case .triggerPulse: words.triggerPulseTest
    case .tone: words.testTone
    case .haptics: words.hapticsToneTest
    case .microphone: words.microphone
    case .stickDrift: words.driftTest
    case .stickRange: words.rangeTest
    }
}

func outcomeResultText(_ result: OutcomeResult, words: L10n = .app) -> String {
    switch result {
    case .worked: words.itWorked
    case .didNotWork: words.itDidNotWork
    }
}

/// The question for the test the pad ran last, once it has finished, and
/// the answers so far, newest first.
struct OutcomesState: Equatable {
    /// Nil while no test waits for its answer.
    let question: String?
    let answers: [String]
    /// Shown before any answer.
    let hint: String?
}

/// A test asks only once it has ended: the outcomes hold it back while it runs.
func outcomesState(slotId: String, outcomes: PadOutcomes, words: L10n = .app) -> OutcomesState {
    let question = outcomes.asking(slotId).map { words.didTestWork(inspectorTestText($0.test, words: words)) }
    let answers = outcomes.answers(slotId).reversed().map { outcome in
        words.answeredTest(inspectorTestText(outcome.test, words: words), outcomeResultText(outcome.result, words: words))
    }
    return OutcomesState(question: question, answers: answers, hint: answers.isEmpty ? words.outcomesHint : nil)
}
