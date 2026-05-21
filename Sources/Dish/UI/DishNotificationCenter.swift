// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation
import SwiftUI

/// Process-scoped notification bus + queue for `DishNotification`s. Owns the
/// `visible` array a `NotificationOverlay` renders as a stacked toast strip.
/// Ports `dish-android/source/notification/DishNotifications.kt`.
///
/// Named `DishNotificationCenter` (not `NotificationCenter`) to avoid the
/// Foundation-type clash. Inject via `.environmentObject(...)` on the root
/// SwiftUI scene; UI sites read `visible` for rendering and call `add(...)`
/// / `dismiss(id:)` to publish + retract banners.
///
/// **Same-key replacement.** Two `add` calls with the same non-nil `key`
/// dismiss the prior banner before the new one shows — state-driven posts
/// ("wifi is off", "session lost") never stack up across navigation. Lives
/// on the publish side, not the renderer side, because the queue itself
/// is the source of truth.
///
/// **Auto-dismiss.** Each banner with a positive `durationMs` schedules
/// itself out after the timer fires. `durationPersistent` opts out;
/// callers retract those by id when the underlying state clears.
@MainActor
final class DishNotificationCenter: ObservableObject {

    @Published private(set) var visible: [DishNotification] = []

    /// Monotonic id source. `Int64` so we can't realistically wrap during
    /// any one app session even at one post per microsecond.
    private var nextId: Int64 = 1
    /// Per-id pending auto-dismiss tasks, so a manual `dismiss(id:)` can
    /// cancel the timer rather than leak it.
    private var pendingDismissals: [Int64: Task<Void, Never>] = [:]
    /// Soft cap: more than this many concurrent banners is visual noise.
    /// New posts above the cap evict the oldest. Matches Android's
    /// `BUFFER = 16` in spirit.
    private nonisolated static let maxVisible = 6

    // MARK: - Publish

    /// Post a notification to the queue. Returns the assigned id so callers
    /// can later `dismiss(id:)` it (e.g. when the underlying state clears
    /// before the auto-dismiss fires). Posts with the same non-nil `key`
    /// replace prior posts with that key.
    @discardableResult
    func add(
        severity: DishNotification.Severity = .info,
        title: String,
        body: String? = nil,
        glyph: String? = nil,
        action: DishNotification.Action? = nil,
        key: String? = nil,
        dismissible: Bool = true,
        durationMs: Int? = nil
    ) -> Int64 {
        // Same-key replacement: pull the prior id off the queue + cancel
        // its pending auto-dismiss before adding the new one. Without
        // this, two "wifi is off" posts in a row would stack up across a
        // user navigation.
        if let key, !key.isEmpty {
            if let priorId = visible.first(where: { $0.key == key })?.id {
                cancelDismissTask(id: priorId)
                visible.removeAll { $0.key == key }
            }
        }
        let id = nextId
        nextId &+= 1
        let resolvedDuration = durationMs ?? Self.defaultDuration(for: severity)
        let notification = DishNotification(
            id: id,
            severity: severity,
            title: title,
            body: body,
            glyph: glyph ?? Self.defaultGlyph(for: severity),
            action: action,
            key: key,
            dismissible: dismissible,
            durationMs: resolvedDuration
        )
        visible.append(notification)
        // Evict oldest if we're over the cap. The newest post stays.
        while visible.count > Self.maxVisible {
            let oldest = visible.removeFirst()
            cancelDismissTask(id: oldest.id)
        }
        if resolvedDuration > 0 {
            scheduleAutoDismiss(id: id, after: resolvedDuration)
        }
        return id
    }

    /// Convenience: post an error banner. Default `durationLong`.
    @discardableResult
    func error(
        title: String,
        body: String? = nil,
        action: DishNotification.Action? = nil,
        key: String? = nil
    ) -> Int64 {
        add(severity: .error, title: title, body: body, action: action, key: key)
    }

    /// Convenience: post a warning banner.
    @discardableResult
    func warn(
        title: String,
        body: String? = nil,
        action: DishNotification.Action? = nil,
        key: String? = nil
    ) -> Int64 {
        add(severity: .warn, title: title, body: body, action: action, key: key)
    }

    /// Convenience: post an info banner.
    @discardableResult
    func info(
        title: String,
        body: String? = nil,
        action: DishNotification.Action? = nil,
        key: String? = nil
    ) -> Int64 {
        add(severity: .info, title: title, body: body, action: action, key: key)
    }

    /// Convenience: post a success banner.
    @discardableResult
    func success(
        title: String,
        body: String? = nil,
        action: DishNotification.Action? = nil,
        key: String? = nil
    ) -> Int64 {
        add(severity: .success, title: title, body: body, action: action, key: key)
    }

    // MARK: - Dismiss

    /// Dismiss a previously-added notification by id. No-op if already gone.
    func dismiss(id: Int64) {
        cancelDismissTask(id: id)
        visible.removeAll { $0.id == id }
    }

    /// Dismiss every banner currently on the queue. Used by the host on
    /// teardown.
    func dismissAll() {
        for (_, task) in pendingDismissals {
            task.cancel()
        }
        pendingDismissals.removeAll()
        visible.removeAll()
    }

    // MARK: - Internals

    /// Same severity-default duration policy Android applies in
    /// `DishNotifications.defaultDurationFor`: INFO / SUCCESS auto-dismiss
    /// quickly; WARN / ERROR linger longer. Persistent banners are explicit
    /// opt-in by passing `durationPersistent` directly.
    private static func defaultDuration(for severity: DishNotification.Severity) -> Int {
        switch severity {
        case .info, .success: return DishNotification.durationShort
        case .warn, .error: return DishNotification.durationLong
        }
    }

    /// SF Symbol fallback when the caller didn't pick one. Maps roughly to
    /// the Android brand-glyph defaults — info pill, check, exclamation,
    /// crossed-circle.
    private static func defaultGlyph(for severity: DishNotification.Severity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func scheduleAutoDismiss(id: Int64, after durationMs: Int) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pendingDismissals.removeValue(forKey: id)
                self.visible.removeAll { $0.id == id }
            }
        }
        pendingDismissals[id] = task
    }

    private func cancelDismissTask(id: Int64) {
        if let task = pendingDismissals.removeValue(forKey: id) {
            task.cancel()
        }
    }
}
