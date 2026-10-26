// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// One binding apply's ears and clock: the host's words merged into one
/// stream, and the budget the desktops give the REST bind. `end` stops both,
/// so an ended run hears nothing more.
@MainActor
final class BindingApplyWatch {

    /// The desktops' budget for the REST bind.
    nonisolated static let restBudgetNs: UInt64 = 8_000_000_000

    private let budgetNs: UInt64
    private var listening: AnyCancellable?
    private var clock: Task<Void, Never>?

    init(budgetNs: UInt64 = BindingApplyWatch.restBudgetNs) {
        self.budgetNs = budgetNs
    }

    func begin(sources: [AnyPublisher<ApplyEvent, Never>], onEvent: @escaping (ApplyEvent) -> Void) {
        end()
        listening = Publishers.MergeMany(sources).sink(receiveValue: onEvent)
        clock = Task { [budgetNs] in
            try? await Task.sleep(nanoseconds: budgetNs)
            guard !Task.isCancelled else { return }
            onEvent(.budgetSpent)
        }
    }

    func end() {
        listening?.cancel()
        listening = nil
        clock?.cancel()
        clock = nil
    }
}
