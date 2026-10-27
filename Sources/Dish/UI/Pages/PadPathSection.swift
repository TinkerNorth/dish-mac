// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import SwiftUI

/// A pad's input path on its Controllers card and in the inspector: the
/// path, or the "Input path" control where both paths work, its reason, the
/// prompt while the path is unproven, and the "Not responding?" check with
/// its countdown, finding and one action.
struct PadPathSection: View {

    struct Actions {
        let check: () -> Void
        let pick: (InputSource) -> Void
        let helpSupport: () -> Void
    }

    let state: PadPathState
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s3) {
            HStack(spacing: DishSpace.s4) {
                path
                Text(state.reason)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = state.prompt {
                Text(prompt)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.primary)
            }
            checkRow
        }
    }

    @ViewBuilder
    private var path: some View {
        if let picker = state.picker {
            Text(picker.title)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
            Picker(picker.title, selection: pickBinding(picker)) {
                ForEach(picker.options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        } else {
            Text(state.path)
                .font(DishFont.monoChip)
                .foregroundColor(DishTheme.primary)
        }
    }

    private var checkRow: some View {
        HStack(spacing: DishSpace.s4) {
            if let countdown = state.check.countdown {
                Text(countdown)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.primary)
            }
            if let verdict = state.check.verdict {
                Text(verdict)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = state.check.action {
                checkAction(action)
            }
            if let link = state.check.link {
                Button(action: actions.check) {
                    Text(link)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.primary)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func checkAction(_ action: CheckActionState) -> some View {
        switch action {
        case let .useDirect(title):
            Button(title, action: useDirect)
                .buttonStyle(DishOutlinedButtonStyle())
        case let .helpSupport(title):
            Button(title, action: actions.helpSupport)
                .buttonStyle(DishOutlinedButtonStyle())
        case let .hint(text):
            Text(text)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickBinding(_ picker: PathPickerState) -> Binding<InputSource> {
        Binding(get: { picker.selected }, set: actions.pick)
    }

    private func useDirect() {
        actions.pick(.direct)
    }
}
