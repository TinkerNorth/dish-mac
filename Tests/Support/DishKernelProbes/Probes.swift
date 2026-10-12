// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishKernel
import Foundation

/// Records every value a publisher emits, in order, so a test can assert the
/// sequence rather than only the final value.
public final class EmissionProbe<Value> {
    public private(set) var values: [Value] = []
    private var subscription: AnyCancellable?

    public init(_ publisher: AnyPublisher<Value, Never>) {
        subscription = publisher.sink { [weak self] value in
            self?.values.append(value)
        }
    }

    public var last: Value? {
        values.last
    }

    public var count: Int {
        values.count
    }
}

/// Probe over a `StateSource`'s state.
public func probe<State: Equatable>(_ source: StateSource<State>) -> EmissionProbe<State> {
    EmissionProbe(source.statePublisher)
}

/// Probe over a `Composer`'s derived state.
public func probe<Output: Equatable>(_ composer: Composer<Output>) -> EmissionProbe<Output> {
    EmissionProbe(composer.statePublisher)
}

/// A `Controller` that records every value `apply` received, for wiring
/// tests that need to see the effect without performing one.
public final class RecordingController<State>: Controller<State> {
    public private(set) var applied: [State] = []
    public private(set) var startCount = 0

    override public func apply(_ value: State) {
        applied.append(value)
    }

    override public func onStarting() {
        startCount += 1
    }
}
