// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Posts every failure the model reports as a toast, the one surface a
/// failure has in the window and on the Connections page. The pairing card's
/// own failures never reach it: the model keeps those on the card. Keyed, so
/// back-to-back failures replace one another instead of stacking. A refused
/// local network comes with the way to System Settings, opened through the
/// scene's `open`.
@MainActor
final class FailureNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(failures: AnyPublisher<ConnectionFailure, Never>, center: DishNotificationCenter, open: @escaping (URL) -> Void) {
        subscription = failures.sink { failure in
            center.error(title: failureText(failure), action: failureAction(failure, open: open), key: "wifi.failure")
        }
    }
}

/// The toast's one way on: Privacy & Security › Local Network once macOS
/// refused the network, nothing for any other failure.
func failureAction(_ failure: ConnectionFailure, open: @escaping (URL) -> Void, words: L10n = .app) -> DishNotification.Action? {
    guard failure == .localNetworkDenied, let url = URL(string: DishLinks.localNetworkSettings) else { return nil }
    return DishNotification.Action(label: words.openSystemSettings) { open(url) }
}
