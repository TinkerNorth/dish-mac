// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Email diagnostics and Save diagnostics: the bundle written by the model,
/// handed to the person's own mail app, or saved where they pick when no
/// mail app takes it.
struct DiagnosticsMailSection: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.diagnosticsMailer) private var mailer
    let mail: DiagnosticsMailState
    @State private var failed = false

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(words.emailDiagnostics, action: email)
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

    private func email() {
        guard let file = model.writeDiagnosticsBundle() else { return failed = true }
        failed = false
        if !mailer.compose(mail, file) { mailer.save(file) }
    }

    private func save() {
        guard let file = model.writeDiagnosticsBundle() else { return failed = true }
        failed = false
        mailer.save(file)
    }
}
