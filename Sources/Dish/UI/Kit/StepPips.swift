// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Where a pip stands against the step on screen.
enum StepPipPhase: Equatable {
    case done
    case current
    case upcoming
}

/// One pip: a dot, and a label beside it when the step has a name.
struct StepPip: Equatable, Identifiable {
    let id: Int
    let label: String?
    let phase: StepPipPhase
}

/// A row of step pips: the welcome's page dots, the setup walk's stages and
/// its binding stage's sub-steps. The current pip is filled in the accent, a
/// done one in the accent's outline, an upcoming one dim.
struct StepPips: View {
    let pips: [StepPip]

    var body: some View {
        HStack(spacing: DishSpace.s6) {
            ForEach(pips) { pip in
                HStack(spacing: DishSpace.s3) {
                    dot(pip.phase)
                    if let label = pip.label {
                        Text(label)
                            .font(pip.phase == .current ? DishFont.control : DishFont.detail)
                            .foregroundColor(pip.phase == .upcoming ? DishTheme.muted : DishTheme.onSurface)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func dot(_ phase: StepPipPhase) -> some View {
        switch phase {
        case .current:
            Circle().fill(DishTheme.primary).frame(width: DishSize.stepDot, height: DishSize.stepDot)
        case .done:
            Circle().stroke(DishTheme.primary, lineWidth: DishSize.hairline).frame(width: DishSize.stepDot, height: DishSize.stepDot)
        case .upcoming:
            Circle().fill(DishTheme.surfaceDim).frame(width: DishSize.stepDot, height: DishSize.stepDot)
                .overlay(Circle().stroke(DishTheme.outline, lineWidth: DishSize.hairline))
        }
    }
}
