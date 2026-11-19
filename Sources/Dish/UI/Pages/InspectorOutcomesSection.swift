// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// "Did it work?" after the test the pad ran last, and the answers so far;
/// the answers ride the diagnostics file.
struct InspectorOutcomesSection: View {

    @EnvironmentObject var model: AppModel
    let slotId: String
    let state: OutcomesState

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.didItWork)
            InspectorCard {
                if let question = state.question {
                    Text(question)
                        .font(DishFont.body)
                        .foregroundColor(DishTheme.onSurface)
                    HStack(spacing: 8) {
                        Button(words.itWorked) { model.answerTestOutcome(slotId: slotId, worked: true) }
                            .buttonStyle(DishOutlinedButtonStyle())
                        Button(words.itDidNotWork) { model.answerTestOutcome(slotId: slotId, worked: false) }
                            .buttonStyle(DishOutlinedButtonStyle())
                    }
                }
                if let hint = state.hint {
                    Text(hint)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.answers, id: \.self) { answer in
                    Text(answer)
                        .font(DishFont.mono)
                        .foregroundColor(DishTheme.onSurface)
                }
            }
        }
    }
}
