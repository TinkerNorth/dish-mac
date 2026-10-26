// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

enum ApplyStepPhase: Equatable {
    case pending
    case active
    case done
    case failed
}

struct ApplyStepRow: Equatable, Identifiable {
    let id: Int
    let title: String
    let phase: ApplyStepPhase
}

/// The line under the steps once a run ends, in its tone.
struct ApplyResultLine: Equatable {
    let text: String
    let color: Color
}

struct ApplyOverlayState: Equatable {
    let eyebrow: String
    let heading: String
    let message: String
    let steps: [ApplyStepRow]
    let result: ApplyResultLine?
    /// Present only while the run may still be cancelled.
    let cancel: String?
    /// Present once the run has ended.
    let close: String?
}

/// "Applying binding…" over the page that started it, not a sheet: one row
/// per step with its state, the outcome once there is one, Cancel while it
/// is honoured and a way back once the run has ended.
struct ApplyOverlay: View {
    let state: ApplyOverlayState
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            DishTheme.scrim
            VStack(alignment: .leading, spacing: DishSpace.s5) {
                Text(state.eyebrow)
                    .textCase(.uppercase)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.primary)
                Text(state.heading)
                    .font(DishFont.title)
                    .foregroundColor(DishTheme.onSurface)
                Text(state.message)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                ForEach(state.steps) { step in
                    ApplyStepLine(step: step)
                }
                if let result = state.result {
                    Text(result.text)
                        .font(DishFont.detail)
                        .foregroundColor(result.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
            .padding(DishSpace.s8)
            .frame(width: DishSize.overlayWidth, alignment: .leading)
            .background(DishTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            if let cancelTitle = state.cancel {
                Button(cancelTitle, action: cancel)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
            if let closeTitle = state.close {
                Button(closeTitle, action: close)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ApplyStepLine: View {
    let step: ApplyStepRow

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            marker
                .frame(width: DishSize.buttonSpinner, height: DishSize.buttonSpinner)
            Text(step.title)
                .font(DishFont.detail)
                .foregroundColor(step.phase == .pending ? DishTheme.muted : DishTheme.onSurface)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch step.phase {
        case .pending:
            Circle().stroke(DishTheme.outline, lineWidth: DishSize.hairline)
        case .active:
            DishSpinner(size: DishSize.buttonSpinner)
        case .done:
            Image(systemName: "checkmark").font(DishFont.micro).foregroundColor(DishTheme.success)
        case .failed:
            Image(systemName: "xmark").font(DishFont.micro).foregroundColor(DishTheme.error)
        }
    }
}
