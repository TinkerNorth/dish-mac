// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What closing the window means when Dish may keep running, and whether the
// user has to be told. Pure: the shell performs, this decides.

import Foundation

public enum WindowCloseAction: Equatable, Sendable {
    case quit
    case hideToBackground
}

/// Hiding with no menu-bar host strands a running process behind no window
/// and no menu, so the preference alone never decides.
public func decideWindowCloseAction(backgroundEnabled: Bool, trayAvailable: Bool) -> WindowCloseAction {
    backgroundEnabled && trayAvailable ? .hideToBackground : .quit
}

/// A window that vanishes without a word reads as a crash.
public func shouldAnnounceBackground(_ action: WindowCloseAction, alreadyAnnounced: Bool) -> Bool {
    action == .hideToBackground && !alreadyAnnounced
}
