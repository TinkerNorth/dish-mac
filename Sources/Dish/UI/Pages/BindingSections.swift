// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// The editor's sections: the pad, where it goes, what it carries there by
/// its own switches and the type it plugs in as, beside the "What carries"
/// table. Every control sends a draft event; nothing here writes.
struct BindingSections: View {

    struct Actions {
        let edit: (BindingDraftEvent) -> Void
        let manageDestinations: () -> Void
    }

    let state: BindingEditorState
    let actions: Actions

    /// The editing column on the left, "What carries" on the right.
    private static let editingColumns = 1

    var body: some View {
        TwoColumnLayout(breakpoint: DishSize.wideBreakpoint, leading: Self.editingColumns, spacing: DishSpace.s8) {
            VStack(alignment: .leading, spacing: DishSpace.s8) {
                BindingSection(title: state.input.title) {
                    Text(state.input.name)
                        .font(DishFont.body)
                        .foregroundColor(DishTheme.onSurface)
                    Text(state.input.detail)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                }
                DestinationSection(state: state.destination, pick: pick, manage: actions.manageDestinations)
                FunctionsSection(state: state.functions, edit: actions.edit)
                emulateSection
            }
            CarriesSection(state: state.carries)
        }
    }

    @ViewBuilder
    private var emulateSection: some View {
        if let emulate = state.emulate {
            BindingSection(title: emulate.title) {
                Picker(emulate.title, selection: typeSelection(emulate)) {
                    ForEach(emulate.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text(emulate.detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
        }
    }

    private func typeSelection(_ emulate: EmulateSectionState) -> Binding<Int?> {
        Binding(get: { emulate.selected }, set: chooseType)
    }

    private func chooseType(_ type: Int?) {
        actions.edit(.chooseType(type))
    }

    private func pick(_ connectionId: String) {
        actions.edit(.chooseDestination(connectionId))
    }
}

/// A section's eyebrow over its body.
struct BindingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            SectionHeader(title: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FunctionsSection: View {
    let state: FunctionsSectionState
    let edit: (BindingDraftEvent) -> Void

    var body: some View {
        BindingSection(title: state.title) {
            ForEach(state.switches) { row in
                Toggle(isOn: switchBinding(row)) {
                    VStack(alignment: .leading, spacing: DishSpace.s1) {
                        Text(row.title)
                            .font(DishFont.detail)
                            .foregroundColor(DishTheme.onSurface)
                        Text(row.detail)
                            .font(DishFont.caption)
                            .foregroundColor(DishTheme.muted)
                    }
                }
                .toggleStyle(.switch)
            }
            if let touchpad = state.touchpad {
                HStack {
                    Text(touchpad.title)
                        .font(DishFont.detail)
                        .foregroundColor(DishTheme.onSurface)
                    Spacer()
                    Picker(touchpad.title, selection: touchpadBinding(touchpad)) {
                        ForEach(touchpad.options) { option in
                            Text(option.label).tag(option.id).disabled(!option.enabled)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            if let nothing = state.nothing {
                Text(nothing)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func switchBinding(_ row: FunctionSwitchState) -> Binding<Bool> {
        Binding(get: { row.on }, set: { edit(switchEvent(row.key, on: $0)) })
    }

    private func touchpadBinding(_ touchpad: TouchpadPickState) -> Binding<TouchpadPick> {
        Binding(get: { touchpad.selected }, set: { edit(.setTouchpad($0)) })
    }
}

struct CarriesSection: View {
    let state: CarriesSectionState

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack {
                SectionHeader(title: state.title)
                Spacer()
                Text(state.summary)
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
            }
            ForEach(state.rows) { row in
                HStack {
                    Text(row.label)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.onSurface)
                    Spacer()
                    Text(row.verdict)
                        .font(DishFont.micro)
                        .foregroundColor(row.color)
                }
                .help(row.help)
            }
        }
        .padding(DishSpace.s6)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(DishTheme.cardStroke, lineWidth: DishSize.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }
}

/// The bar pinned under the editor: Unbind while the page opened on a
/// binding, the hint, Cancel and Apply.
struct BindingBar: View {

    struct Actions {
        let unbind: () -> Void
        let cancel: () -> Void
        let apply: () -> Void
    }

    let state: BindingBarState
    let actions: Actions

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            if let unbind = state.unbind {
                Button(unbind, role: .destructive, action: actions.unbind)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
            Text(state.hint)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
            Spacer()
            Button(state.cancel, action: actions.cancel)
                .buttonStyle(DishOutlinedButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(state.apply, action: actions.apply)
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!state.applyEnabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DishSpace.page)
        .padding(.vertical, DishSpace.s6)
    }
}
