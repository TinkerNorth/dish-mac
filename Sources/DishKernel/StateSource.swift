// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// Owns one piece of state and exposes it read-only. The owner mutates it
/// through `setState`, which is distinct-until-changed: an equal value is
/// not published. Subclasses wrap a socket, a timer, a cache or a setting;
/// `start`/`stop` are opt-in lifecycle hooks.
open class StateSource<State: Equatable>: ObservableObject {
    @Published public private(set) var state: State

    public init(initial: State) {
        state = initial
    }

    /// The current state, as a publisher that replays the latest value to a
    /// new subscriber and then emits on every change.
    public var statePublisher: AnyPublisher<State, Never> {
        $state.eraseToAnyPublisher()
    }

    open func start() {}

    open func stop() {}

    /// Replace the state. Equal values are dropped before publishing.
    public func setState(_ next: State) {
        guard next != state else { return }
        state = next
    }

    /// Replace the state with the result of `reducer` applied to the current
    /// one, with the same distinct-until-changed rule.
    public func updateState(_ reducer: (State) -> State) {
        setState(reducer(state))
    }
}
