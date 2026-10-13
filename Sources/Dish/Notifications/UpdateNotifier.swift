// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Words the update checker's notices as banners.
@MainActor
final class UpdateNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(checker: UpdateChecker, center: DishNotificationCenter) {
        subscription = checker.notices.sink { event in
            switch event.notice {
            case .available:
                center.info(title: L10n.app.updateAvailableToast(event.version), key: "update.available")
            case .unsupported:
                center.warn(title: L10n.app.versionUnsupported, key: "update.unsupported")
            }
        }
    }
}
