// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import Combine
import DishEngine
import Foundation

/// Builds the engine's lifecycle signals from AppKit's workspace and
/// application notifications. The centers are parameters so the mapping is
/// testable without a running app.
func appKitLifecycleSignals(workspace: NotificationCenter, application: NotificationCenter = .default) -> LifecycleSignals {
    LifecycleSignals(
        willSleep: voidPublisher(workspace, NSWorkspace.willSleepNotification),
        didWake: voidPublisher(workspace, NSWorkspace.didWakeNotification),
        willTerminate: voidPublisher(application, NSApplication.willTerminateNotification)
    )
}

private func voidPublisher(_ center: NotificationCenter, _ name: Notification.Name) -> AnyPublisher<Void, Never> {
    center.publisher(for: name)
        .map(discardNotification)
        .eraseToAnyPublisher()
}

private func discardNotification(_ notification: Notification) {}
