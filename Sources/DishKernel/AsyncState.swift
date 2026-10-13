// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The four states of one request, with the last good value retained across
/// a refresh or a failure so a screen shows a spinner or an error chip over
/// known content rather than a blank. `Failure` is a typed reason the UI
/// localizes, not a string.
public struct AsyncState<Value: Equatable, Failure: Equatable>: Equatable {
    public enum Phase: Equatable {
        case idle
        case loading
        case success
        case error
    }

    public let phase: Phase
    /// The last good value, kept through `loading` and `error`.
    public let data: Value?
    /// Populated only in the `error` phase.
    public let error: Failure?
    /// True when `data` was carried over from an earlier success.
    public let stale: Bool

    public init(phase: Phase, data: Value?, error: Failure?, stale: Bool) {
        self.phase = phase
        self.data = data
        self.error = error
        self.stale = stale
    }

    public static var idle: AsyncState {
        AsyncState(phase: .idle, data: nil, error: nil, stale: false)
    }

    /// Start a fresh load with nothing to show meanwhile.
    public static var loadingFresh: AsyncState {
        AsyncState(phase: .loading, data: nil, error: nil, stale: false)
    }

    /// Start a refresh, keeping the previous value on screen as stale.
    public func toLoading() -> AsyncState {
        AsyncState(phase: .loading, data: data, error: nil, stale: data != nil)
    }

    public func toSuccess(_ value: Value) -> AsyncState {
        AsyncState(phase: .success, data: value, error: nil, stale: false)
    }

    /// A revalidation that confirmed the previous value (an HTTP 304).
    public func toRevalidated() -> AsyncState {
        AsyncState(phase: .success, data: data, error: nil, stale: data != nil)
    }

    public func toError(_ reason: Failure) -> AsyncState {
        AsyncState(phase: .error, data: data, error: reason, stale: data != nil)
    }

    public var isLoading: Bool {
        phase == .loading
    }

    public var isError: Bool {
        phase == .error
    }

    public var isSuccess: Bool {
        phase == .success
    }
}
