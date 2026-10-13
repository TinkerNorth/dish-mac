// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// The host-app events the engine reacts to, as publishers, so the engine
/// never imports AppKit: the app builds them from `NSApplication` and
/// `NSWorkspace`, tests drive them with subjects.
package struct LifecycleSignals {
    /// The app stopped being the active application: held buttons must be
    /// released server-side, because the controller callbacks stop reaching
    /// this process.
    package let focusLost: AnyPublisher<Void, Never>
    /// The machine is about to sleep: same release-all, since a forced lid
    /// close may never deliver a focus loss.
    package let willSleep: AnyPublisher<Void, Never>
    /// The machine woke: sockets may be dead and addresses moved, so resting
    /// rows reconnect now rather than waiting out the backoff curve.
    package let didWake: AnyPublisher<Void, Never>

    package init(
        focusLost: AnyPublisher<Void, Never>,
        willSleep: AnyPublisher<Void, Never>,
        didWake: AnyPublisher<Void, Never>
    ) {
        self.focusLost = focusLost
        self.willSleep = willSleep
        self.didWake = didWake
    }

    /// Signals that never fire, for an engine with no host app.
    package static let none = LifecycleSignals(
        focusLost: Empty().eraseToAnyPublisher(),
        willSleep: Empty().eraseToAnyPublisher(),
        didWake: Empty().eraseToAnyPublisher()
    )
}
