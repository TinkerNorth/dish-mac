// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The Dish replacement for ad-hoc inline error banners. A theme-styled,
/// stack-of-toasts surface rendered by `NotificationOverlay` at the bottom
/// of every window.
///
/// Ports `dish-android/source/notification/DishNotifications.kt` + its
/// `core/model/DishNotification.kt` value type. The Android version's
/// `glyph` (a `@DrawableRes`) becomes an SF Symbol name on Mac; the
/// `action` callback uses the same "label + handler" shape.
///
/// **Pattern position:** pure value type. The publisher
/// (`DishNotificationCenter`) is an `ObservableObject` injected into the
/// SwiftUI environment; emit sites call `add(...)` directly.
///
/// Field rationale:
///   - `severity` picks the rail / icon colour. INFO / SUCCESS auto-dismiss
///     after `durationShort`; WARN / ERROR after `durationLong`. Persistent
///     banners are explicit opt-in via `durationPersistent`.
///   - `title` is the imperative one-line headline (the part VoiceOver
///     reads first). Keep < ~50 chars so the pill doesn't wrap awkwardly.
///   - `body` is the optional one-line monospace detail (network ip,
///     error code, etc.). Hidden when nil.
///   - `glyph` is an SF Symbol name; defaults pick one per severity.
///   - `action` is the right-edge CTA. The label is short
///     ("RETRY" / "SETTINGS"), and tapping it dismisses the notification.
///   - `key` de-duplicates: two posts with the same non-nil key replace
///     each other rather than stacking. Use for state-driven feedback
///     ("wifi is off" must never queue twice).
///   - `dismissible` controls whether the close button is rendered.
///   - `durationMs` is in ms; `0` means persistent (stay until dismissed).
struct DishNotification: Identifiable, Equatable {
    /// Monotonic id assigned by `DishNotificationCenter.add`. Use this
    /// handle to call `dismiss(id:)` if the underlying state clears before
    /// the auto-dismiss timer fires.
    let id: Int64
    let severity: Severity
    let title: String
    let body: String?
    let glyph: String?
    let action: Action?
    let key: String?
    let dismissible: Bool
    let durationMs: Int

    enum Severity: String, Equatable, CaseIterable {
        case info, success, warn, error
    }

    /// Tap target inside the banner. `label` renders as an outlined button
    /// at the right of the row; `handler` runs on the main actor and the
    /// notification auto-dismisses after the tap. The handler should be
    /// idempotent — a fast double-tap can fire it twice before dismissal
    /// lands.
    struct Action: Equatable {
        let label: String
        let handler: () -> Void

        static func == (lhs: Action, rhs: Action) -> Bool {
            // Closure identity isn't comparable; compare the only visible
            // field. Two actions with the same label on different posts
            // are functionally equivalent for `Equatable` use sites
            // (animation diffing, dedup) — the actual handler runs only
            // on tap, where identity doesn't matter.
            lhs.label == rhs.label
        }
    }

    /// Roughly Toast.LENGTH_SHORT equivalent — matches Android's 3.5 s.
    static let durationShort = 3_500
    /// Roughly Toast.LENGTH_LONG equivalent — matches Android's 6 s.
    static let durationLong = 6_000
    /// Stays up until `DishNotificationCenter.dismiss(id:)` or a same-key
    /// replacement.
    static let durationPersistent = 0
}
