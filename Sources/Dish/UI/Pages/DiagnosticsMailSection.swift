// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// Report a problem, Ask a question and Save diagnostics: the first two
/// open the report page, which hands the file to the person's own mail app;
/// the third saves the file where they pick.
struct DiagnosticsMailSection: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    @Environment(\.diagnosticsMailer) private var mailer
    @State private var failed = false

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(words.reportAProblem, action: reportAProblem)
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(words.askAQuestion, action: askAQuestion)
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(words.saveDiagnostics, action: save)
                    .buttonStyle(DishOutlinedButtonStyle())
                Spacer(minLength: 0)
            }
            Text(words.emailDiagnosticsDetail)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if failed {
                Text(words.diagnosticsFileFailed)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.error)
            }
        }
    }

    private func reportAProblem() {
        navigation.send(.push(.supportReport(category: .other)))
    }

    private func askAQuestion() {
        navigation.send(.push(.supportReport(category: .question)))
    }

    private func save() {
        guard let file = model.writeDiagnosticsBundle() else { return failed = true }
        failed = false
        mailer.save(file)
    }
}
