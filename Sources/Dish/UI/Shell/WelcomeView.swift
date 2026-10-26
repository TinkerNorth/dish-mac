// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The first-run welcome, over the whole window and not a sheet: the
/// desktops' four pages, their dots, and Back / Skip / Next, Finish on the
/// last. Esc is Skip; both Skip and Finish complete the welcome, and Finish
/// goes on into the setup walk.
struct WelcomeView: View {

    @EnvironmentObject var navigation: NavigationStore
    @Environment(\.openURL) private var openURL
    @State private var page = 0

    private var state: WelcomeState {
        welcomeState(page: page)
    }

    var body: some View {
        let state = state
        ZStack(alignment: .bottom) {
            DishTheme.background
                .ignoresSafeArea()
            hero(state)
                .frame(maxWidth: DishSize.welcomeColumn)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: DishSpace.page) {
                StepPips(pips: state.dots)
                bar(state)
            }
            .padding(DishSpace.page)
        }
        .onExitCommand(perform: skip)
    }

    private func hero(_ state: WelcomeState) -> some View {
        VStack(spacing: DishSpace.s8) {
            if state.showsMark {
                BrandIcon(kind: .dish, state: .default, size: DishSize.welcomeMark)
            }
            SectionHeader(title: state.eyebrow)
            Text(state.title)
                .font(DishFont.pageTitle)
                .foregroundColor(DishTheme.onSurface)
                .multilineTextAlignment(.center)
            Text(state.body)
                .font(DishFont.body)
                .foregroundColor(DishTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let download = state.download {
                Button(download.title) { open(download.url) }
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        }
    }

    private func bar(_ state: WelcomeState) -> some View {
        HStack(spacing: DishSpace.s4) {
            if let back = state.back {
                Button(back, action: goBack)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
            Spacer()
            Button(state.skip, action: skip)
                .buttonStyle(DishOutlinedButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(state.primary, action: primary)
                .buttonStyle(DishOutlinedButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func goBack() {
        if let previous = state.previousPage { page = previous }
    }

    /// Next turns the page; on the last page it is Finish.
    private func primary() {
        guard let next = state.nextPage else { return navigation.send(.welcome(.finish)) }
        page = next
    }

    private func skip() {
        navigation.send(.welcome(.skip))
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}
