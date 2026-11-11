// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What the Direct reader does when the user picks Direct for a pad that is
// not open yet. Opening a device whose collections include a keyboard, a
// mouse or a touchpad makes macOS ask for Input Monitoring, and asking
// blocks the calling thread until the user answers (`IOHIDRequestAccess`
// waits on TCC with no timeout), so the reader asks off its own thread and
// opens only once the answer is in.

import Foundation

/// The process's Input Monitoring standing, as `IOHIDCheckAccess` reads it
/// without prompting.
public enum InputMonitoringAccess: Equatable, Sendable {
    case granted
    case denied
    /// The user has not been asked yet.
    case undecided
}

/// The reader's next step for one claim.
public enum ClaimStep: Equatable, Sendable {
    /// Open the device now: no prompt can come of it.
    case open
    /// Ask for Input Monitoring off the reader's thread, then decide again.
    case ask
    /// Tell the user why Dish cannot read the pad.
    case refuse
}

/// A device that needs no permission, or one already granted, opens at
/// once; a denial is refused without asking again; an undecided standing is
/// asked once, and still undecided after asking is a refusal.
public func claimStep(needsInputMonitoring: Bool, access: InputMonitoringAccess, asked: Bool) -> ClaimStep {
    guard needsInputMonitoring else { return .open }
    switch access {
    case .granted: return .open
    case .denied: return .refuse
    case .undecided: return asked ? .refuse : .ask
    }
}
