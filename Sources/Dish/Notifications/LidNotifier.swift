// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Says once, on the wake, that a closed lid put the Mac to sleep mid-stream:
/// macOS gives an app no way to keep a lidded Mac awake on its own.
@MainActor
final class LidNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(lidPausedStreaming: AnyPublisher<Void, Never>, center: DishNotificationCenter) {
        subscription = lidPausedStreaming.sink {
            center.info(title: L10n.app.streamingPausedWhileLidClosed, key: "power.lid")
        }
    }
}
