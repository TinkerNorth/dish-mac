// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import SwiftUI

/// The navigation machine at the app layer: it applies events, runs the
/// effects the machine returns (the rail's collapse and the welcome's
/// completion persist), and hands `NavigationSplitView` and
/// `NavigationStack` their bindings.
@MainActor
final class NavigationStore: ObservableObject {

    @Published private(set) var state: NavigationState

    private let preferences: UiPreferenceStore
    private let onboarding: OnboardingPreferenceStore
    private let activateWindow: () -> Void

    init(preferences: UiPreferenceStore, onboarding: OnboardingPreferenceStore, activateWindow: @escaping () -> Void) {
        self.preferences = preferences
        self.onboarding = onboarding
        self.activateWindow = activateWindow
        state = NavigationState(railCollapsed: preferences.railCollapsed, showingWelcome: !onboarding.welcomeCompleted)
    }

    func send(_ event: NavigationEvent) {
        let step = reduceNavigation(state, event)
        state = step.state
        step.effects.forEach(run)
    }

    private func run(_ effect: NavigationEffect) {
        switch effect {
        case let .persistRail(collapsed): preferences.setRailCollapsed(collapsed)
        case .activateWindow: activateWindow()
        case .markWelcomeComplete: onboarding.markWelcomeComplete()
        }
    }

    /// The rail never hides: the split view's own sidebar button collapses
    /// it to the icon strip and back.
    var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { .all }, set: { self.columnVisibilityChanged($0) })
    }

    private func columnVisibilityChanged(_ visibility: NavigationSplitViewVisibility) {
        if visibility != .all { send(.toggleRail) }
    }

    /// The stack's path; a pop the stack makes itself is a `pop` event.
    var path: Binding<[Page]> {
        Binding(get: { self.state.path }, set: { self.pathChanged($0) })
    }

    private func pathChanged(_ path: [Page]) {
        let shorter = path.count < state.path.count
        let longer = path.count > state.path.count
        if shorter { send(path.isEmpty ? .popToRoot : .pop) }
        if longer, let page = path.last { send(.push(page)) }
    }
}
