// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Posts every engine failure as a toast, the one surface a failure has in
/// the window and the Connections sheet. A failure a sheet shows inline (the
/// pairing sheet, under its PIN field) is not posted as well. Keyed, so
/// back-to-back failures replace one another instead of stacking.
@MainActor
final class FailureNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(
        failures: AnyPublisher<ConnectionFailure, Never>,
        shownInline: @escaping () -> Bool,
        center: DishNotificationCenter
    ) {
        subscription = failures.sink { failure in
            guard !shownInline() else { return }
            center.error(title: failureText(failure), key: "wifi.failure")
        }
    }
}
