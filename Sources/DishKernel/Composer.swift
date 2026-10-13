// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// One value purely derived from one to four upstream publishers. The
/// transform runs once at construction (the upstreams replay their current
/// value) and again on every upstream change; equal results are dropped, so a
/// consumer never sees a stale initial value or a no-op emit. Keep the
/// transform a free function so it is testable on its own.
public final class Composer<Output: Equatable>: ObservableObject {
    @Published public private(set) var state: Output
    private var subscription: AnyCancellable?

    public var statePublisher: AnyPublisher<Output, Never> {
        $state.eraseToAnyPublisher()
    }

    public init<A>(
        _ first: some Publisher<A, Never>,
        initial: Output,
        transform: @escaping (A) -> Output
    ) {
        state = initial
        subscription = first.map(transform).sink(receiveValue: adopt)
    }

    public init<A, B>(
        _ first: some Publisher<A, Never>,
        _ second: some Publisher<B, Never>,
        initial: Output,
        transform: @escaping (A, B) -> Output
    ) {
        state = initial
        subscription = Publishers.CombineLatest(first, second)
            .map(transform)
            .sink(receiveValue: adopt)
    }

    public init<A, B, C>(
        _ first: some Publisher<A, Never>,
        _ second: some Publisher<B, Never>,
        _ third: some Publisher<C, Never>,
        initial: Output,
        transform: @escaping (A, B, C) -> Output
    ) {
        state = initial
        subscription = Publishers.CombineLatest3(first, second, third)
            .map(transform)
            .sink(receiveValue: adopt)
    }

    public init<A, B, C, D>(
        _ first: some Publisher<A, Never>,
        _ second: some Publisher<B, Never>,
        _ third: some Publisher<C, Never>,
        _ fourth: some Publisher<D, Never>,
        initial: Output,
        transform: @escaping (A, B, C, D) -> Output
    ) {
        state = initial
        subscription = Publishers.CombineLatest4(first, second, third, fourth)
            .map(transform)
            .sink(receiveValue: adopt)
    }

    private func adopt(_ next: Output) {
        guard next != state else { return }
        state = next
    }
}
