// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// The host-app events the engine reacts to, as publishers, so the engine
/// never imports AppKit: the app builds them from `NSWorkspace`, tests drive
/// them with subjects. Losing focus is not one of them: the controller keeps
/// reaching Dish while another app is in front, so nothing is released then.
package struct LifecycleSignals {
    /// The machine is about to sleep: held buttons are released on the host,
    /// every session is closed the graceful way, and the lid is read.
    package let willSleep: AnyPublisher<Void, Never>
    /// The machine woke: sockets may be dead and the network another, so the
    /// sessions reopen now rather than waiting out the backoff curve, and the
    /// LAN is scanned again.
    package let didWake: AnyPublisher<Void, Never>

    package init(willSleep: AnyPublisher<Void, Never>, didWake: AnyPublisher<Void, Never>) {
        self.willSleep = willSleep
        self.didWake = didWake
    }

    /// Signals that never fire, for an engine with no host app.
    package static let none = LifecycleSignals(
        willSleep: Empty().eraseToAnyPublisher(),
        didWake: Empty().eraseToAnyPublisher()
    )
}
