// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// "Report a problem" and "Ask a question": the category, the person's own
/// words, the controller it concerns, what the file will hold and what it
/// never holds, Preview file, then Continue in Mail. Opening the page asks
/// each connected host for its own view; nothing leaves the Mac until the
/// person presses Send in their mail app.
struct SupportReportPage: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.diagnosticsMailer) private var mailer
    @Environment(\.pasteboard) private var pasteboard
    @State private var form: SupportReportForm
    @State private var preview: String?
    @State private var failed = false
    @State private var noMail: String?

    private let words = L10n.app

    init(category: SupportReportCategory) {
        _form = State(initialValue: SupportReportForm(category: category))
    }

    private var state: SupportReportPageState {
        supportReportPageState(form: form, facts: model.shellFacts, mail: model.diagnosticsMailFacts)
    }

    var body: some View {
        let state = state
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s8) {
                Text(state.intro)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                fields(state)
                holds(state)
                actions(state)
                if let preview {
                    previewBlock(preview)
                }
            }
            .padding(DishSpace.page)
        }
        .onAppear { model.pageAppeared(.supportReport) }
        .onDisappear { model.pageDisappeared(.supportReport) }
    }

    private func fields(_ state: SupportReportPageState) -> some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            label(state.categoryLabel)
            Picker(state.categoryLabel, selection: $form.category) {
                ForEach(state.categories) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .fixedSize()
            label(state.textLabel)
            TextEditor(text: $form.text)
                .font(DishFont.detail)
                .frame(minHeight: DishSize.reportTextHeight)
                .overlay(RoundedRectangle(cornerRadius: DishSize.chipRadius).stroke(DishTheme.cardStroke, lineWidth: DishSize.hairline))
            label(state.controllerLabel)
            Picker(state.controllerLabel, selection: controllerBinding(state)) {
                ForEach(state.controllers) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func holds(_ state: SupportReportPageState) -> some View {
        VStack(alignment: .leading, spacing: DishSpace.s3) {
            SectionHeader(title: state.holdsTitle)
            ForEach(state.holds, id: \.self) { line in
                Text(line)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(state.never)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actions(_ state: SupportReportPageState) -> some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack(spacing: DishSpace.s4) {
                Button(previewToggleText(showing: preview != nil)) { togglePreview(state) }
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.canContinue)
                Button(state.continueLabel) { continueInMail(state) }
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.canContinue)
                Spacer(minLength: 0)
            }
            if let preparing = state.preparing {
                Text(preparing)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            if failed {
                Text(words.diagnosticsFileFailed)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.error)
            }
            if let noMail {
                Text(noMail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewBlock(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DishSpace.s4)
        }
        .frame(height: DishSize.reportPreviewHeight)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.chipRadius))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DishFont.caption)
            .foregroundColor(DishTheme.muted)
    }

    /// The picker shows the suggestion resolved; a pick replaces it.
    private func controllerBinding(_ state: SupportReportPageState) -> Binding<ReportControllerChoice> {
        Binding(get: { state.controllerSelection }, set: pickController)
    }

    private func pickController(_ choice: ReportControllerChoice) {
        form.controller = choice
    }

    private func togglePreview(_ state: SupportReportPageState) {
        guard preview == nil else { return preview = nil }
        preview = model.supportReportPreview(state.draft)
    }

    private func continueInMail(_ state: SupportReportPageState) {
        guard let file = model.writeSupportReport(state.draft) else { return failed = true }
        failed = false
        guard !mailer.compose(state.mail, file) else { return noMail = nil }
        pasteboard.copy(supportReportMailText(state.mail))
        noMail = noMailNote(savedAt: mailer.save(file), recipient: state.mail.recipient)
    }
}
