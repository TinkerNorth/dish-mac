// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// "Help support this controller": a guided press sequence over one device,
/// opened alongside macOS while the page shows, then the report as
/// read-only text with Copy and "Open a GitHub issue". Nothing leaves the
/// Mac unless the user pastes it.
struct HelpSupportPage: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.pasteboard) private var pasteboard
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    let deviceKey: String

    private var state: HelpSupportPageState {
        helpSupportPageState(deviceKey: deviceKey, facts: model.shellFacts)
    }

    var body: some View {
        let state = state
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s6) {
                Text(state.intro)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                content(state.content)
            }
            .padding(DishSpace.page)
        }
        .onAppear { model.pageAppeared(.helpSupport(deviceKey: deviceKey)) }
        .onDisappear { model.pageDisappeared(.helpSupport(deviceKey: deviceKey)) }
    }

    @ViewBuilder
    private func content(_ content: HelpSupportContent) -> some View {
        switch content {
        case let .waiting(note):
            HStack(spacing: DishSpace.s4) {
                DishSpinner(size: DishSize.buttonSpinner)
                Text(note)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.onSurface)
            }
        case let .step(step):
            stepCard(step)
        case let .finished(result):
            resultCard(result)
        }
    }

    private func stepCard(_ step: SupportStepState) -> some View {
        InspectorCard {
            Text(step.device)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            Text(step.progress)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.muted)
            Text(step.prompt)
                .font(DishFont.title)
                .foregroundColor(DishTheme.primary)
            Text(step.seen)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.muted)
            HStack(spacing: DishSpace.s4) {
                Button(step.next, action: model.nextSupportStep)
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(step.skip, action: model.skipSupportStep)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        }
    }

    private func resultCard(_ result: SupportResultState) -> some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack(spacing: DishSpace.s4) {
                Button(result.copy) { copy(result.text) }
                    .buttonStyle(DishOutlinedButtonStyle())
                if let url = result.issueURL {
                    Button(result.issue) { openURL(url) }
                        .buttonStyle(DishOutlinedButtonStyle())
                }
                if copied {
                    Text(result.copied)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.success)
                }
            }
            Text(result.note)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
            InspectorCard {
                Text(result.text)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.onSurface)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copy(_ text: String) {
        pasteboard.copy(text)
        copied = true
    }
}
