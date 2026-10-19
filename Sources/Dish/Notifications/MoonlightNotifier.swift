// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import Foundation

/// Words the Moonlight hosts' events as banners. A host that holds another
/// device's app offers to close it from the banner.
@MainActor
final class MoonlightNotifier: ObservableObject {
    private var subscription: AnyCancellable?

    func bind(
        events: AnyPublisher<MoonlightConnectionEvent, Never>,
        center: DishNotificationCenter,
        quitApp: @escaping (MoonlightHost) -> Void
    ) {
        subscription = events.sink { event in
            guard let notice = moonlightNotice(for: event) else { return }
            let action = notice.quitHost.map { host in
                DishNotification.Action(label: L10n.app.closeTheAppOn(moonlightHostTitle(host))) { quitApp(host) }
            }
            Self.post(notice, action: action, to: center)
        }
    }

    private static func post(_ notice: MoonlightNotice, action: DishNotification.Action?, to center: DishNotificationCenter) {
        switch notice.severity {
        case .error: _ = center.error(title: notice.title, body: notice.body, action: action, key: notice.key)
        case .warn: _ = center.warn(title: notice.title, body: notice.body, action: action, key: notice.key)
        case .info: _ = center.info(title: notice.title, body: notice.body, action: action, key: notice.key)
        case .success: _ = center.success(title: notice.title, body: notice.body, action: action, key: notice.key)
        }
    }
}
