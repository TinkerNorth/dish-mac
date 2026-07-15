// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pure mapping from a SESSION_CLOSE (0x000F) reason byte to the session's
// follow-up action (contract §Session-close notify). Ports dish-linux
// Network/CloseNotify.h; reason values match satellite/src/core/types.h
// CLOSE_REASON_*.

import Foundation

/// MSG_SESSION_CLOSE reason byte (contract §UDP messages).
public enum CloseReason: UInt8, Sendable {
    /// Server going down (broadcast before shutdown).
    case shutdown = 0
    /// Admin kick — transient by design; a retrying client may reconnect.
    case kicked = 1
    /// Superseded by a newer PUT (sent to the OLD token).
    case replaced = 2
    /// Trust revoked — terminal until the user re-pairs.
    case unpaired = 3
}

/// What the session layer does after an authenticated close-notify.
public enum CloseAction: Equatable, Sendable {
    /// shutdown / kicked: transient — reconnect on the exponential backoff curve.
    case backoffRetry
    /// replaced: a newer PUT already owns the session — do nothing further.
    case stayDown
    /// unpaired: trust revoked — drop the stored key, surface the stale
    /// "needs pairing" state, STOP retrying.
    case dropKeyAndStale
}

/// Map a close reason to its teardown action.
public func closeActionForReason(_ r: CloseReason) -> CloseAction {
    switch r {
    case .unpaired: .dropKeyAndStale
    case .replaced: .stayDown
    case .shutdown, .kicked: .backoffRetry
    }
}

/// Raw-byte variant for the receive path: an unknown FUTURE reason byte
/// degrades to a transient retry, exactly like the C++ ports' default arm.
public func closeAction(forReasonByte raw: UInt8) -> CloseAction {
    guard let reason = CloseReason(rawValue: raw) else { return .backoffRetry }
    return closeActionForReason(reason)
}

/// Lowercase wire name for a close reason (diagnostics/UI cue; protocol
/// constant, never localized).
public func closeReasonName(_ r: CloseReason) -> String {
    switch r {
    case .shutdown: "shutdown"
    case .kicked: "kicked"
    case .replaced: "replaced"
    case .unpaired: "unpaired"
    }
}

/// Raw-byte variant; unknown bytes read as "shutdown" (the C++ default arm).
public func closeReasonName(forReasonByte raw: UInt8) -> String {
    guard let reason = CloseReason(rawValue: raw) else { return "shutdown" }
    return closeReasonName(reason)
}
