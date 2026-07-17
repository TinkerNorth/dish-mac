// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pure classifiers that turn an HTTP status + the protocol-relevant body
// fields into a decision the session layer acts on. Free functions only so
// the rules unit-test without sockets. These encode the contract's error
// model (§Error model, §hmacProof) once, in one place. Ports dish-linux
// Network/RestOutcome.h, minus its terminal/retryable boolean helpers: the
// shell's decision arms act per-verdict (the two terminal arms return before
// the retry arm), so a boolean partition had no behavior-identical call site
// and was dropped rather than kept dead (W4C-F1).

import Foundation

/// What a REST exchange means to the caller, independent of which route it was.
public enum RestVerdict: Equatable, Sendable {
    /// 2xx with the fields we need.
    case ok
    /// 401 NOT_PAIRED | BAD_PROOF — TERMINAL: drop key, re-pair.
    case unauthorized
    /// 409 — TERMINAL: client/server protocol skew.
    case versionMismatch
    /// 503 — retryable later.
    case shuttingDown
    /// Transport failure / empty body (status 0) — retryable.
    case unreachable
    /// Any other non-2xx with a body — usually retryable.
    case serverError
}

/// The decoded shape every REST reply carries through this layer: the HTTP
/// status, whether the body parsed at all, and the optional `code` (401
/// cause). A status of 0 means the transport never produced a response (the
/// gateway's synthesised-failure sentinel).
public struct RestReply: Equatable, Sendable {
    public var status: Int
    public var bodyParsed: Bool
    /// `NOT_PAIRED` | `BAD_PROOF` on a 401, else empty.
    public var code: String

    public init(status: Int = 0, bodyParsed: Bool = false, code: String = "") {
        self.status = status
        self.bodyParsed = bodyParsed
        self.code = code
    }
}

/// Classify a generic authenticated REST reply (PUT/GET/DELETE session /
/// controller). `code` is consulted on 401 so a NOT_PAIRED and a BAD_PROOF
/// both surface as `.unauthorized` (both terminal — contract §hmacProof).
public func classifyRest(_ reply: RestReply) -> RestVerdict {
    guard reply.status != 0, reply.bodyParsed else { return .unreachable }
    return switch reply.status {
    case 200 ... 299: .ok
    case 401: .unauthorized
    case 409: .versionMismatch
    case 503: .shuttingDown
    default: .serverError
    }
}
