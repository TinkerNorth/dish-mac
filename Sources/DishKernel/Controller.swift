// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// A side effect driven by a state. `start()` applies the upstream's current
/// value and then every change; it is idempotent. `stop()` tears the
/// subscription down and can be overridden for an effect that must survive a
/// restart. Subclasses implement `apply`, which is the one place the effect
/// happens.
open class Controller<State> {
    private let upstream: AnyPublisher<State, Never>
    private var subscription: AnyCancellable?
    public private(set) var isStarted = false

    public init(upstream: AnyPublisher<State, Never>) {
        self.upstream = upstream
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        onStarting()
        subscription = upstream.sink { [weak self] value in
            self?.apply(value)
        }
    }

    open func stop() {
        cancelCollection()
    }

    open func apply(_ value: State) {}

    /// Hook for re-arming state a previous `stop()` tore down.
    open func onStarting() {}

    public func cancelCollection() {
        subscription = nil
        isStarted = false
    }
}
