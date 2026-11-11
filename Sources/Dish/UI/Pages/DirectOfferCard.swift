// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import SwiftUI

/// A pad Dish could read directly once the user asks: what reading it does
/// to the pad, macOS's refusal when there was one, and the ways on: Use
/// Direct, System Settings, or handing the pad back as it came.
struct DirectOfferCard: View {

    @Environment(\.openURL) private var openURL
    let state: DirectOfferCardState
    let pick: (InputSource, String) -> Void

    var body: some View {
        EmptyStateCard(title: state.title, message: state.message, hint: state.hint) {
            ForEach(state.actions) { action in
                button(action)
            }
        }
    }

    @ViewBuilder
    private func button(_ action: DirectOfferAction) -> some View {
        switch action {
        case let .useDirect(title):
            Button(title, action: useDirect)
                .buttonStyle(DishOutlinedButtonStyle())
        case let .openSettings(link):
            Button(link.title) { open(link.url) }
                .buttonStyle(DishOutlinedButtonStyle())
        case let .stopReading(title):
            Button(title, action: stopReading)
                .buttonStyle(DishOutlinedButtonStyle())
        }
    }

    private func useDirect() {
        pick(.direct, state.id)
    }

    /// Standard is the hand-back: macOS keeps the pad as a keyboard and mouse.
    private func stopReading() {
        pick(.standard, state.id)
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}
