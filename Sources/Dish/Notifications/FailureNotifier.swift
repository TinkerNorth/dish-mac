// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Posts every engine failure as a banner. Keyed, so back-to-back failures
/// replace one another instead of stacking.
@MainActor
final class FailureNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(model: AppModel, center: DishNotificationCenter) {
        subscription = model.failures.sink { failure in
            center.error(title: failureText(failure), key: "wifi.failure")
        }
    }
}
