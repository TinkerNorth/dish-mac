// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishKernel
import Foundation

/// The queue of banners the `NotificationOverlay` renders, newest last.
/// Two posts with the same non-nil `key` replace each other; a banner with a
/// positive duration dismisses itself; the queue never holds more than
/// `maxVisible`, evicting the oldest.
@MainActor
final class DishNotificationCenter: StateSource<[DishNotification]> {

    private var nextId: Int64 = 1
    private var pendingDismissals: [Int64: Task<Void, Never>] = [:]
    private nonisolated static let maxVisible = 6

    init() {
        super.init(initial: [])
    }

    var visible: [DishNotification] {
        state
    }

    // MARK: - Publish

    /// Returns the id so the caller can dismiss early.
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
        replacePriorPost(withKey: key)
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
        updateState { Array(($0 + [notification]).suffix(Self.maxVisible)) }
        cancelDismissTasksForEvicted()
        if resolvedDuration > 0 {
            scheduleAutoDismiss(id: id, after: resolvedDuration)
        }
        return id
    }

    @discardableResult
    func error(title: String, body: String? = nil, action: DishNotification.Action? = nil, key: String? = nil) -> Int64 {
        add(severity: .error, title: title, body: body, action: action, key: key)
    }

    @discardableResult
    func warn(title: String, body: String? = nil, action: DishNotification.Action? = nil, key: String? = nil) -> Int64 {
        add(severity: .warn, title: title, body: body, action: action, key: key)
    }

    @discardableResult
    func info(title: String, body: String? = nil, action: DishNotification.Action? = nil, key: String? = nil) -> Int64 {
        add(severity: .info, title: title, body: body, action: action, key: key)
    }

    @discardableResult
    func success(title: String, body: String? = nil, action: DishNotification.Action? = nil, key: String? = nil) -> Int64 {
        add(severity: .success, title: title, body: body, action: action, key: key)
    }

    // MARK: - Dismiss

    func dismiss(id: Int64) {
        cancelDismissTask(id: id)
        updateState { $0.filter { $0.id != id } }
    }

    func dismissAll() {
        for (_, task) in pendingDismissals {
            task.cancel()
        }
        pendingDismissals.removeAll()
        setState([])
    }

    // MARK: - Internals

    private func replacePriorPost(withKey key: String?) {
        guard let key, !key.isEmpty else { return }
        guard let priorId = state.first(where: { $0.key == key })?.id else { return }
        cancelDismissTask(id: priorId)
        updateState { $0.filter { $0.key != key } }
    }

    /// An eviction drops the oldest banner from the queue; its timer goes too.
    private func cancelDismissTasksForEvicted() {
        let live = Set(state.map(\.id))
        for id in pendingDismissals.keys where !live.contains(id) {
            cancelDismissTask(id: id)
        }
    }

    /// Info and success auto-dismiss quickly; warnings and errors linger.
    private static func defaultDuration(for severity: DishNotification.Severity) -> Int {
        switch severity {
        case .info, .success: DishNotification.durationShort
        case .warn, .error: DishNotification.durationLong
        }
    }

    private static func defaultGlyph(for severity: DishNotification.Severity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func scheduleAutoDismiss(id: Int64, after durationMs: Int) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pendingDismissals.removeValue(forKey: id)
                self.updateState { $0.filter { $0.id != id } }
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
