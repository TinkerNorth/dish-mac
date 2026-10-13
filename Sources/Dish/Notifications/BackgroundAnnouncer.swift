// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import UserNotifications

/// The IO edge that tells the user, once, that a closed window did not quit
/// Dish. The decision to say it is `shouldAnnounceBackground` in the core;
/// this is only the saying.
protocol BackgroundAnnouncing: AnyObject {
    func announce()
}

/// A system notification, because by then there is no window to say it in.
/// A bare binary without a bundle has no notification centre and stays
/// quiet; so does a test process, which never constructs this type.
final class BackgroundAnnouncer: BackgroundAnnouncing {

    private let words = L10n.app

    func announce() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = words.stillRunningTitle
        content.body = words.stillRunningBody
        let request = UNNotificationRequest(identifier: "dish.background", content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}
