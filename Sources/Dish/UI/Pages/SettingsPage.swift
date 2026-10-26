// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// Settings, in the desktops' order: Appearance and Forwarded features on
/// the left, the rest on the right once the page is wide enough for two
/// columns. Each switch is a global preference: Dish forwards input, it does
/// not remap it.
struct SettingsPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore

    private var state: SettingsPageState {
        settingsPageState(facts: model.shellFacts)
    }

    var body: some View {
        ScrollView {
            TwoColumnLayout(breakpoint: DishSize.wideBreakpoint, leading: 2, spacing: DishSpace.page) {
                AppearanceSection(state: state)
                ForwardedFeaturesSection(state: state)
                ControllerTuningSection(state: state)
                WindowSection(state: state)
                PowerSection(state: state)
                DiagnosticsSection(state: state, push: push)
                UpdatesSection(state: state)
                AboutSection(state: state, push: push, select: select)
            }
            .padding(DishSpace.page)
        }
        .onAppear { model.pageAppeared(.settings) }
        .onDisappear { model.pageDisappeared(.settings) }
    }

    private func push(_ page: Page) {
        navigation.send(.push(page))
    }

    private func select(_ destination: Destination) {
        navigation.send(.select(destination))
    }
}

/// A section: its eyebrow over its rows.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            SectionHeader(title: title)
            content()
        }
    }
}

/// A footnote under a section's rows.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DishFont.caption)
            .foregroundColor(DishTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
