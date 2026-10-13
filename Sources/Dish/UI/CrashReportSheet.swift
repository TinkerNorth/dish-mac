// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import SwiftUI

/// The crash report the user reviews before anything leaves this Mac: the
/// redacted text, a copy, a prefilled issue in the browser, or the bin.
struct CrashReportSheet: View {

    @Environment(\.dismiss) private var dismiss
    let report: String
    let onDiscard: () -> Void
    @State private var copied = false

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(words.crashReport)
                .font(DishFont.title)
                .foregroundColor(DishTheme.onSurface)
            Text(words.crashReportIntro)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            reportText
            actions
        }
        .padding(20)
        .frame(width: 640)
        .background(DishTheme.background)
    }

    private var reportText: some View {
        ScrollView {
            Text(report)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 260, maxHeight: 360)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(words.copy, action: copyReport)
                .buttonStyle(DishOutlinedButtonStyle())
            if copied {
                Text(words.reportCopied)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.success)
            }
            Spacer()
            Button(words.discard) {
                onDiscard()
                dismiss()
            }
            .buttonStyle(DishOutlinedButtonStyle())
            Button(words.close) { dismiss() }
                .buttonStyle(DishOutlinedButtonStyle())
            Button(words.reportOnGitHub, action: openIssue)
                .buttonStyle(DishOutlinedButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        copied = true
    }

    private func openIssue() {
        guard let url = crashIssueURL(report) else { return }
        NSWorkspace.shared.open(url)
    }
}
