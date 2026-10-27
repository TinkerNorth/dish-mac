// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// "Check the buttons" for one generic pad, pushed from its card's "Layout
/// guessed" chip or its menu: the walk asks for one control at a time and
/// the pad's next raw change becomes it, with Skip, Reset to defaults and
/// the whole table under the prompt. The engine listens while the page shows.
struct CheckButtonsPage: View {

    @EnvironmentObject var model: AppModel
    let slotId: String

    private var state: CheckButtonsPageState {
        checkButtonsPageState(slotId: slotId, facts: model.shellFacts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s6) {
                content(state.content)
            }
            .padding(DishSpace.page)
        }
        .onAppear { model.pageAppeared(.checkButtons(slotId: slotId)) }
        .onDisappear { model.pageDisappeared(.checkButtons(slotId: slotId)) }
    }

    @ViewBuilder
    private func content(_ content: CheckButtonsContent) -> some View {
        switch content {
        case .waiting:
            DishSpinner(size: DishSize.buttonSpinner)
        case let .missing(title, body), let .notRemappable(title, body):
            EmptyStateCard(title: title, message: body)
        case let .walking(walk):
            walkCard(walk)
            rows(walk.rows)
            Text(walk.footnote)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
    }

    private func walkCard(_ walk: CheckButtonsWalkState) -> some View {
        InspectorCard {
            Text(walk.name)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            if let progress = walk.progress {
                Text(progress)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.muted)
            }
            Text(walk.prompt)
                .font(DishFont.title)
                .foregroundColor(DishTheme.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DishSpace.s4) {
                if let skip = walk.skip {
                    Button(skip, action: model.skipButtonCheckStep)
                        .buttonStyle(DishOutlinedButtonStyle())
                }
                if let again = walk.checkAgain {
                    Button(again, action: model.restartButtonCheck)
                        .buttonStyle(DishOutlinedButtonStyle())
                }
                Button(walk.reset, action: model.resetButtonCheck)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        }
    }

    private func rows(_ rows: [RemapRowState]) -> some View {
        InspectorCard {
            ForEach(rows) { row in
                HStack(spacing: DishSpace.s4) {
                    Text(row.label)
                        .font(DishFont.detail)
                        .foregroundColor(row.ink)
                    Spacer(minLength: DishSpace.s4)
                    Text(row.value)
                        .font(DishFont.mono)
                        .foregroundColor(row.ink)
                }
            }
        }
    }
}
