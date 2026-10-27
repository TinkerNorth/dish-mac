// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Says that a controller keeps disconnecting, once per burst of three
/// drops within a minute (the engine sends one name per burst), with the
/// connection hint; keyed by the pad, so a later burst replaces it.
@MainActor
final class PadNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(keepsDisconnecting: AnyPublisher<String, Never>, center: DishNotificationCenter) {
        subscription = keepsDisconnecting.sink { name in
            let words = L10n.app
            center.warn(title: words.padKeepsDisconnecting(name), body: words.connectionHint, key: "pad.disconnects.\(name)")
        }
    }
}
