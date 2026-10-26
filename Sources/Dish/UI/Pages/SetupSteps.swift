// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// The walk's one question on screen. Every answer is an intent that lands
/// in the walk's draft; nothing here writes.
struct SetupStepView: View {

    @EnvironmentObject var model: AppModel
    let content: SetupStepContent

    var body: some View {
        switch content {
        case let .input(step): SetupInputStepView(step: step, pick: model.pickSetupPad)
        case let .destination(step): SetupDestinationStepView(step: step)
        case let .type(step): SetupTypeStepView(step: step, edit: model.editSetup)
        case let .session(step): SetupSessionStepView(step: step)
        case let .feel(step): SetupFeelStepView(step: step, edit: model.editSetup)
        case let .review(step): SetupReviewStepView(step: step)
        }
    }
}

/// A step's question over the line that says what it is for.
struct SetupHeadingView: View {
    let heading: SetupHeading

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s2) {
            Text(heading.title)
                .font(DishFont.title)
                .foregroundColor(DishTheme.onSurface)
            Text(heading.subtitle)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupInputStepView: View {
    let step: SetupInputStep
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            SetupHeadingView(heading: step.heading)
            if let waiting = step.waiting {
                EmptyStateCard(title: waiting.title, message: waiting.message)
            }
            ForEach(step.pads) { pad in
                SetupPadRowView(row: pad, pick: pick)
            }
        }
    }
}

private struct SetupPadRowView: View {
    let row: SetupPadRow
    let pick: (String) -> Void

    var body: some View {
        Button(action: pickThis) {
            HStack(spacing: DishSpace.s4) {
                Image(systemName: row.look.glyph)
                    .font(DishFont.icon)
                    .foregroundColor(row.look.ink)
                BrandIcon(kind: .pad, state: .default, size: ConnectionRowParts.glyphSize)
                VStack(alignment: .leading, spacing: DishSpace.s1) {
                    Text(row.name)
                        .font(DishFont.control)
                        .foregroundColor(DishTheme.onSurface)
                    Text(row.detail)
                        .font(DishFont.microRegular)
                        .foregroundColor(DishTheme.muted)
                }
                Spacer()
            }
            .padding(DishSpace.s4)
            .background(row.look.fill)
            .clipShape(RoundedRectangle(cornerRadius: DishSize.chipRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickThis() {
        pick(row.id)
    }
}

private struct SetupTypeStepView: View {
    let step: SetupTypeStep
    let edit: (BindingDraftEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            SetupHeadingView(heading: step.heading)
            if let emulate = step.emulate {
                Picker(emulate.title, selection: typeSelection(emulate)) {
                    ForEach(emulate.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text(emulate.detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            if let waiting = step.waiting {
                Text(waiting)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
            }
        }
    }

    private func typeSelection(_ emulate: EmulateSectionState) -> Binding<Int?> {
        Binding(get: { emulate.selected }, set: chooseType)
    }

    private func chooseType(_ type: Int?) {
        edit(.chooseType(type))
    }
}

private struct SetupSessionStepView: View {

    @EnvironmentObject var model: AppModel
    let step: SetupSessionStep

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            SetupHeadingView(heading: step.heading)
            if let picker = step.picker {
                MoonlightAppPicker(state: picker, pick: pickApp)
            }
        }
    }

    private func pickApp(_ appId: String) {
        model.pickMoonlightApp(step.hostId, appId: appId)
    }
}

private struct SetupFeelStepView: View {
    let step: SetupFeelStep
    let edit: (BindingDraftEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            SetupHeadingView(heading: step.heading)
            FunctionsSection(state: step.functions, edit: edit)
            SettingsFootnote(text: step.footnote)
        }
    }
}

private struct SetupReviewStepView: View {
    let step: SetupReviewStep

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            SetupHeadingView(heading: step.heading)
            VStack(alignment: .leading, spacing: DishSpace.s4) {
                ForEach(step.lines) { line in
                    HStack {
                        Text(line.label)
                            .font(DishFont.caption)
                            .foregroundColor(DishTheme.muted)
                        Spacer()
                        Text(line.value)
                            .font(DishFont.control)
                            .foregroundColor(DishTheme.onSurface)
                    }
                }
            }
            .settingsCard()
            CarriesSection(state: step.carries)
            SettingsFootnote(text: step.footnote)
        }
    }
}
