// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Help & FAQ, pushed from Settings ▸ Setup & help: the way into setup,
/// the desktops' questions folded under their sections, and the links.
struct HelpPage: View {

    @EnvironmentObject var navigation: NavigationStore
    @Environment(\.openURL) private var openURL

    private let state = helpPageState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s8) {
                Button(state.walkThrough, action: walkThrough)
                    .buttonStyle(DishOutlinedButtonStyle())
                ForEach(state.sections) { section in
                    VStack(alignment: .leading, spacing: DishSpace.s4) {
                        SectionHeader(title: section.title)
                        ForEach(section.entries) { entry in
                            HelpEntryView(entry: entry)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: DishSpace.s4) {
                    SectionHeader(title: state.linksTitle)
                    ForEach(state.links) { link in
                        Button(link.title) { open(link.url) }
                            .buttonStyle(DishOutlinedButtonStyle())
                    }
                }
            }
            .frame(maxWidth: DishSize.helpColumn, alignment: .leading)
            .padding(DishSpace.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func walkThrough() {
        navigation.send(.openSetup(seedSlotId: nil))
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}

/// One question, folded until it is opened.
private struct HelpEntryView: View {
    let entry: HelpEntryState

    var body: some View {
        DisclosureGroup {
            Text(entry.answer)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DishSpace.s2)
        } label: {
            Text(entry.question)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
        }
        .tint(DishTheme.primary)
    }
}
