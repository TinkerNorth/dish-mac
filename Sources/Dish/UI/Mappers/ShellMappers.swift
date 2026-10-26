// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// The picture a rail item draws. No two destinations share a silhouette,
/// so the icon strip stays navigable.
enum RailGlyph: Equatable {
    case dish
    case pad
    case satellite
    case heart
    case gear
}

/// One rail item as drawn.
struct RailItemState: Equatable, Identifiable {
    let destination: Destination
    let label: String
    let glyph: RailGlyph
    let active: Bool
    /// The dot on the glyph, nil when there is nothing to call out.
    let badge: Color?

    var id: Destination {
        destination
    }
}

/// The pill the shell shows on every page while a controller streams.
struct StreamingPillState: Equatable {
    let text: String
    let configure: String
    let configureHelp: String
}

/// The app-wide microphone chip.
struct MicChipState: Equatable {
    let text: String
    let live: Bool
    let help: String
}

/// The line under the page title.
enum ShellSubline: Equatable {
    /// The dashboard headline and summary, under the dot that colours them.
    case status(headline: String, summary: String, accent: Color)
    /// A page's own line.
    case note(String)
}

/// Everything the shell draws around a page.
struct ShellState: Equatable {
    let top: [RailItemState]
    let footer: [RailItemState]
    let version: String
    let railCollapsed: Bool
    let title: String
    let showsBack: Bool
    let pill: StreamingPillState?
    let mic: MicChipState?
    let subline: ShellSubline
}

/// What the shell reads beyond the navigation state.
struct ShellInputs {
    let facts: ShellFacts
    let connections: [ConnectionSummary]
    let mic: MicIndicatorState
}

func shellState(_ navigation: NavigationState, _ inputs: ShellInputs, words: L10n = .app) -> ShellState {
    let badge = updateBadge(inputs.facts.update)
    let top: [Destination] = [.home, .controllers, .connections]
    let footer: [Destination] = [.support, .settings]
    return ShellState(
        top: top.map { railItem($0, navigation: navigation, badge: nil, words: words) },
        footer: footer.map { railItem($0, navigation: navigation, badge: $0 == .settings ? badge : nil, words: words) },
        version: words.railVersion(inputs.facts.update.currentVersion),
        railCollapsed: navigation.railCollapsed,
        title: pageTitle(navigation, words: words),
        showsBack: !navigation.path.isEmpty,
        pill: streamingPill(inputs.facts.wake, words: words),
        mic: shellMicChip(inputs.mic, words: words),
        subline: shellSubline(navigation, connections: inputs.connections, words: words)
    )
}

private func railItem(_ destination: Destination, navigation: NavigationState, badge: Color?, words: L10n) -> RailItemState {
    RailItemState(
        destination: destination,
        label: destinationTitle(destination, words: words),
        glyph: railGlyph(destination),
        active: navigation.destination == destination,
        badge: badge
    )
}

func railGlyph(_ destination: Destination) -> RailGlyph {
    switch destination {
    case .home: .dish
    case .controllers: .pad
    case .connections: .satellite
    case .support: .heart
    case .settings: .gear
    }
}

func destinationTitle(_ destination: Destination, words: L10n = .app) -> String {
    switch destination {
    case .home: words.home
    case .controllers: words.controllers
    case .connections: words.connections
    case .support: words.supportDish
    case .settings: words.settings
    }
}

func pushedPageTitle(_ page: Page, words: L10n = .app) -> String {
    switch page {
    case .diagnostics: words.diagnostics
    case .inspector: words.inspectorTitle
    case .crashReport: words.crashReport
    case .licenses: words.openSourceLicenses
    case .moonlightHosts: words.moonlightHosts
    case .configureBinding: words.configureBinding
    case .deadZones: words.deadZonesAndMotion
    }
}

/// The top page's title: the pushed page's, or the destination's at the root.
func pageTitle(_ navigation: NavigationState, words: L10n = .app) -> String {
    guard let page = navigation.path.last else { return destinationTitle(navigation.destination, words: words) }
    return pushedPageTitle(page, words: words)
}

/// A dot on Settings while a newer release waits; the warning tone when
/// this build is no longer supported. Checking is silent and a failure is a
/// Settings matter, not a call to action.
func updateBadge(_ update: UpdateStatus) -> Color? {
    switch update.phase {
    case .available: update.required ? DishTheme.warning : DishTheme.primary
    case .disabled, .idle, .checking, .upToDate, .failed: nil
    }
}

/// The pill names how far the machine is held, so it never claims a hold
/// the preferences stopped asking for; hidden while nothing streams.
func streamingPill(_ wake: WakeState, words: L10n = .app) -> StreamingPillState? {
    guard wake.streamingSlotCount > 0 else { return nil }
    return StreamingPillState(
        text: streamingPillText(wake.reach, words: words),
        configure: words.configure,
        configureHelp: words.configureKeepAwake
    )
}

private func streamingPillText(_ reach: KeepAwakeReach, words: L10n) -> String {
    switch reach {
    case .systemAndDisplay: words.streamingDisplayKeptAwake
    case .system: words.streamingComputerKeptAwake
    case .none: words.streaming
    }
}

/// Hidden while no microphone is armed; one word and one click for every
/// armed microphone at once.
func shellMicChip(_ state: MicIndicatorState, words: L10n = .app) -> MicChipState? {
    switch state {
    case .hidden: nil
    case .live: MicChipState(text: words.micLive, live: true, help: words.micLiveClickToMute)
    case .muted: MicChipState(text: words.micMuted, live: false, help: words.micMutedClickToUnmute)
    }
}

/// The pages that carry their own line; every other page carries the
/// dashboard's.
func shellSubline(_ navigation: NavigationState, connections: [ConnectionSummary], words: L10n = .app) -> ShellSubline {
    let liveCount = liveConnections(connections).count
    let status = ShellSubline.status(
        headline: dashboardStatusText(connections, words: words),
        summary: dashboardSummaryText(connections, words: words),
        accent: dashboardAccent(liveCount: liveCount)
    )
    switch navigation.path.last {
    case .licenses: return .note(words.licensesSubtitle)
    case .diagnostics, .inspector, .crashReport, .moonlightHosts, .configureBinding, .deadZones: return status
    case nil: return navigation.destination == .support ? .note(words.donationsKeepItFree) : status
    }
}
