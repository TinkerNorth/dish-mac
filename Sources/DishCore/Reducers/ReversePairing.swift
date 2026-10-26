// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The decision core of operator-approved pairing (Path B, contract
// §Pairing): the dish shows a client PIN, files it with `POST /api/pair`,
// then polls `GET /api/pair/status` until the operator answers on the
// satellite. The engine owns the timer and the call and feeds each reply and
// the clock through here. Ports the desktops' `core/reducer/ReversePairing.h`
// and the approval half of their `RestOutcome.h`.

import Foundation

/// Where one satellite's approval request stands, as the pairing card shows it.
public enum ReversePairingPhase: Equatable, Sendable {
    /// No request filed.
    case idle
    /// Filed; the operator has not answered.
    case awaiting
    /// The operator approved; the session is opening.
    case approved
    /// The operator declined.
    case declined
    /// The deadline passed without an answer, or the request never landed.
    case timedOut
    /// The satellite's TLS certificate no longer matches its pin.
    case identityChanged
    /// The satellite speaks no protocol version this app does.
    case versionMismatch
}

/// One `/api/pair/status` answer, reduced to what the decision reads.
/// `reachable` is false when the transport produced no JSON body.
public struct ApprovalReply: Equatable, Sendable {
    public let reachable: Bool
    public let status: String
    public let sharedKey: String?

    public init(reachable: Bool, status: String = "", sharedKey: String? = nil) {
        self.reachable = reachable
        self.status = status
        self.sharedKey = sharedKey
    }
}

/// What one poll means.
public enum ApprovalVerdict: Equatable, Sendable {
    case approved(sharedKeyHex: String)
    case pending
    case declined
    case unreachable
}

/// What the poll does next.
public enum ReversePairingAction: Equatable, Sendable {
    /// Adopt the key and open the session.
    case approve(sharedKeyHex: String)
    case decline
    case timeOut
    case keepPolling
}

private let approvedStatus = "approved"
private let noneStatus = "none"
private let legacyDeniedStatus = "denied"
private let sharedKeyHexLength = 64

/// The satellite never says "denied": a decline erases the request, so the
/// poll reads "none", which means a decline exactly when a "pending" was seen
/// in this attempt. An "approved" without a usable key stays pending, so a
/// malformed key is never adopted.
public func classifyApproval(_ reply: ApprovalReply, sawPending: Bool) -> ApprovalVerdict {
    guard reply.reachable else { return .unreachable }
    let usableKey = reply.sharedKey.flatMap(usableSharedKey)
    let isApproved = reply.status == approvedStatus
    if isApproved, let usableKey {
        return .approved(sharedKeyHex: usableKey)
    }
    let erasedAfterPending = reply.status == noneStatus && sawPending
    let legacyDenied = reply.status == legacyDeniedStatus
    return erasedAfterPending || legacyDenied ? .declined : .pending
}

/// Total over every verdict and clock reading. A decline is terminal
/// whatever the clock; a pending answer or a transport blip waits until the
/// deadline, which is inclusive: at `elapsedMs == deadlineMs` the budget is
/// spent.
public func nextReversePairingAction(verdict: ApprovalVerdict, elapsedMs: Int, deadlineMs: Int) -> ReversePairingAction {
    switch verdict {
    case let .approved(sharedKeyHex): .approve(sharedKeyHex: sharedKeyHex)
    case .declined: .decline
    case .pending, .unreachable: waitOrTimeOut(elapsedMs: elapsedMs, deadlineMs: deadlineMs)
    }
}

private func waitOrTimeOut(elapsedMs: Int, deadlineMs: Int) -> ReversePairingAction {
    elapsedMs >= deadlineMs ? .timeOut : .keepPolling
}

/// A pairing key on the wire: 32 bytes as 64 hex digits of either case. The
/// alphabet is checked, not just the length, so a malformed key never
/// reaches the hex decoder.
public func isSharedKeyHex(_ key: String) -> Bool {
    let rightLength = key.utf8.count == sharedKeyHexLength
    return rightLength && key.utf8.allSatisfy(isHexDigitByte)
}

private func usableSharedKey(_ key: String) -> String? {
    isSharedKeyHex(key) ? key : nil
}

private func isHexDigitByte(_ byte: UInt8) -> Bool {
    let digit = (0x30 ... 0x39).contains(byte)
    let upper = (0x41 ... 0x46).contains(byte)
    let lower = (0x61 ... 0x66).contains(byte)
    return digit || upper || lower
}
