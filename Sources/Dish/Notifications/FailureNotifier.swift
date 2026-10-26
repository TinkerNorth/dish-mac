// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Posts every failure the model reports as a toast, the one surface a
/// failure has in the window and the Connections sheet. The pairing card's
/// own failures never reach it: the model keeps those on the card. Keyed, so
/// back-to-back failures replace one another instead of stacking.
@MainActor
final class FailureNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(failures: AnyPublisher<ConnectionFailure, Never>, center: DishNotificationCenter) {
        subscription = failures.sink { failure in
            center.error(title: failureText(failure), key: "wifi.failure")
        }
    }
}
