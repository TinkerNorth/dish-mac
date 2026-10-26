// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The crash report the user reviews before anything leaves this Mac: the
/// redacted text, a copy, a prefilled issue in the browser, or the bin.
struct CrashReportPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    @Environment(\.pasteboard) private var pasteboard
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    private let words = L10n.app

    private var state: CrashReportPageState {
        crashReportPageState(facts: model.shellFacts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            Text(words.crashReportIntro)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            reportText
            actions
        }
        .padding(DishSpace.page)
        .onAppear { model.pageAppeared(.crashReport) }
    }

    private var reportText: some View {
        ScrollView {
            Text(state.report)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DishSpace.s5)
        }
        .frame(maxHeight: .infinity)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }

    private var actions: some View {
        HStack(spacing: DishSpace.s4) {
            Button(words.copy, action: copyReport)
                .buttonStyle(DishOutlinedButtonStyle())
            if copied {
                Text(words.reportCopied)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.success)
            }
            Spacer()
            Button(words.discard, action: discard)
                .buttonStyle(DishOutlinedButtonStyle())
            Button(words.reportOnGitHub, action: openIssue)
                .buttonStyle(DishOutlinedButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func copyReport() {
        pasteboard.copy(state.report)
        copied = true
    }

    private func discard() {
        model.discardCrashLog()
        navigation.send(.pop)
    }

    private func openIssue() {
        guard let url = state.issueURL else { return }
        openURL(url)
    }
}
