// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// What the Moonlight hosts page is drawn from: the rows, the pads that ride
/// them, the hosts' facts, and the PIN a host minted.
struct MoonlightHostsInputs {
    let connections: [ConnectionSummary]
    let slots: [ControllerSlot]
    let facts: ConnectionsFacts
    let pin: MoonlightPinPrompt?
}

struct MoonlightHostsPageState: Equatable {
    let foundTitle: String
    let scan: ScanControlState
    let addTitle: String
    let list: MoonlightListState
    let addForm: AddHostFormState
    let forget: ForgetDialogState
}

enum MoonlightListState: Equatable {
    case looking(EmptyStateModel)
    case nothing(NothingFoundState)
    case rows([MoonlightHostRowState])
}

struct MoonlightHostRowState: Equatable, Identifiable {
    let id: String
    let title: String
    let kindLine: String
    let address: String
    let dot: Color
    let chips: [ChipState]
    let statusLine: String?
    let app: AppPickerState?
    let actions: [MoonlightActionState]
    /// Nil for a host a scan found and nothing remembers: there is nothing to forget.
    let menu: RowMenuState?
    let pin: MoonlightPinCardState?
}

struct MoonlightActionState: Equatable, Identifiable {
    let kind: MoonlightRowAction
    let title: String
    let enabled: Bool

    var id: String {
        title
    }
}

/// The app a host's session starts, once a probe has listed them: Auto (the
/// first the host lists) or the pick, shared by every pad on the host.
struct AppPickerState: Equatable {
    let label: String
    let options: [AppOption]
    let selection: String
    let note: String?
}

struct AppOption: Equatable, Identifiable {
    let id: String
    let title: String
}

/// The PIN the dish minted, shown in the host's row for the user to type
/// into the host's own page while the exchange waits on it.
struct MoonlightPinCardState: Equatable {
    let title: String
    let cells: [String]
    let prompt: String
    let waiting: String
    let cancel: String
    let newCode: String
}

/// The inline form that adds a host mDNS does not reach.
struct AddHostFormState: Equatable {
    let heading: String
    let message: String
    let field: AddressFieldState
    let cancel: String
}

func moonlightHostsPageState(_ inputs: MoonlightHostsInputs, draft: String, words: L10n = .app) -> MoonlightHostsPageState {
    let rejected = inputs.facts.rejectedAddress == .moonlight
    let addressError = rejected ? words.enterTheHostAddress : nil
    let field = addressField(draft: draft, placeholder: words.moonlightAddressPlaceholder, error: addressError, words: words)
    return MoonlightHostsPageState(
        foundTitle: words.found,
        scan: scanControl(scanning: inputs.facts.moonlight.scanning, words: words),
        addTitle: words.addByAddressEllipsis,
        list: moonlightList(inputs, words: words),
        addForm: addHostForm(field, words: words),
        forget: forgetDialog(inputs.facts.pendingForget, connections: inputs.connections, slots: inputs.slots, words: words)
    )
}

func addHostForm(_ field: AddressFieldState, words: L10n = .app) -> AddHostFormState {
    AddHostFormState(heading: words.addAHostByAddress, message: words.enterTheHostAddressOrName, field: field, cancel: words.cancel)
}

/// Empty is a real state, and it says so differently while a sweep runs.
func moonlightList(_ inputs: MoonlightHostsInputs, words: L10n = .app) -> MoonlightListState {
    let rows = moonlightRows(known: inputs.connections, discovered: inputs.facts.moonlight.discovered)
    guard rows.isEmpty else { return .rows(rows.map { moonlightHostRow($0, inputs, words: words) }) }
    guard !inputs.facts.moonlight.scanning else {
        return .looking(EmptyStateModel(title: words.lookingForMoonlightHosts, message: words.scanningForGameStreamHosts))
    }
    let card = EmptyStateModel(title: words.noMoonlightHostsFound, message: words.moonlightHostAppearsHere)
    let getApp = URL(string: DishLinks.sunshine)
    return .nothing(NothingFoundState(card: card, getApp: words.getSunshine, getAppURL: getApp, secondary: words.addByAddressEllipsis))
}

func moonlightHostRow(_ row: MoonlightRow, _ inputs: MoonlightHostsInputs, words: L10n = .app) -> MoonlightHostRowState {
    switch row {
    case let .known(summary): knownHostRow(summary, inputs, words: words)
    case let .discovered(host): discoveredHostRow(host, inputs, words: words)
    }
}

/// The trust word, how many controllers ride the host and the link's tier;
/// the way out of where its session stands; Forget behind the ⋯ menu.
func knownHostRow(_ summary: ConnectionSummary, _ inputs: MoonlightHostsInputs, words: L10n = .app) -> MoonlightHostRowState {
    let title = connectionTitle(summary)
    let phase = inputs.facts.moonlight.phases[summary.id]
    let trust = ChipState(text: moonlightTrustText(summary.live, words: words), color: moonlightTrustColor(summary.live))
    let controllers = moonlightControllersText(summary, words: words).map { ChipState(text: $0, color: DishTheme.success) }
    let pairing = inputs.facts.moonlight.pairingInFlight.contains(summary.id)
    return MoonlightHostRowState(
        id: summary.id,
        title: title,
        kindLine: words.moonlightHostKind,
        address: summary.address,
        dot: linkDotColor(summary.live),
        chips: [tierChip(.moonlight, words: words), trust] + [controllers].compactMap { $0 },
        statusLine: moonlightStatusLine(summary, phase: phase, words: words),
        app: appPicker(summary.id, host: title, facts: inputs.facts.moonlight, words: words),
        actions: moonlightActions(summary, phase: phase, host: title, enabled: !pairing, words: words),
        menu: RowMenuState(label: words.moreActionsFor(title), forget: words.forget),
        pin: pinCard(on: summary.id, inputs.pin, words: words)
    )
}

/// The row's buttons, each worded for its host; none runs while a pairing is in flight.
func moonlightActions(
    _ summary: ConnectionSummary,
    phase: MoonlightSessionPhase?,
    host: String,
    enabled: Bool,
    words: L10n = .app
) -> [MoonlightActionState] {
    moonlightRowActions(summary, phase: phase).map { action in
        MoonlightActionState(kind: action, title: moonlightActionText(action, host: host, words: words), enabled: enabled)
    }
}

/// A host only a scan knows: not paired, and Pair now is its one action.
func discoveredHostRow(_ host: MoonlightHost, _ inputs: MoonlightHostsInputs, words: L10n = .app) -> MoonlightHostRowState {
    let pairing = inputs.facts.moonlight.pairingInFlight.contains(host.id)
    let pair = MoonlightActionState(kind: .pair, title: pairing ? words.pairing : words.pairNow, enabled: !pairing)
    return MoonlightHostRowState(
        id: host.id,
        title: moonlightHostTitle(host),
        kindLine: words.moonlightHostKind,
        address: host.address,
        dot: DishTheme.muted,
        chips: [tierChip(.moonlight, words: words), ChipState(text: words.notPaired, color: DishTheme.muted)],
        statusLine: nil,
        app: nil,
        actions: [pair],
        menu: nil,
        pin: pinCard(on: host.id, inputs.pin, words: words)
    )
}

/// Auto first, then each listed app by its title, its id when it has none.
func appPicker(_ hostId: String, host: String, facts: MoonlightFacts, words: L10n = .app) -> AppPickerState? {
    guard let apps = facts.apps[hostId], !apps.isEmpty else { return nil }
    let picked = facts.pickedApps[hostId] ?? ""
    let listed = apps.map { AppOption(id: $0.id, title: $0.title.isEmpty ? $0.id : $0.title) }
    return AppPickerState(
        label: words.app,
        options: [AppOption(id: "", title: words.auto)] + listed,
        selection: picked,
        note: picked.isEmpty ? words.withoutAPick(host) : nil
    )
}

func pinCard(on hostId: String, _ prompt: MoonlightPinPrompt?, words: L10n = .app) -> MoonlightPinCardState? {
    guard let prompt, prompt.host.id == hostId else { return nil }
    let host = moonlightHostTitle(prompt.host)
    return MoonlightPinCardState(
        title: words.pairWith(host),
        cells: prompt.pin.map(String.init),
        prompt: words.typePinInto(prompt.pin, host),
        waiting: words.waitingForTheHostToAcceptThePin,
        cancel: words.cancel,
        newCode: words.newCode
    )
}
