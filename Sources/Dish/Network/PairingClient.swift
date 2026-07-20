// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Async pair handshake with a Satellite server: HTTPS `POST /api/pair` on
/// the client API port plus the path-B `GET /api/pair/status` poll (contract
/// §Pairing). Mirrors dish-linux `Network/PairingClient` + dish-android's
/// `PairingApproval`.
///
/// Both PIN paths ride the same POST:
/// - **Path A** (operator PIN): the satellite's PIN typed into this dish →
///   the response carries the shared key directly.
/// - **Path B** (client PIN): this dish shows `clientPin`, the operator
///   approves it on the satellite → the response is `pending:true` and the
///   key arrives via the status poll exactly once.
///
/// `protocolVersion` rides in every request; an incompatible server rejects
/// with 409, surfaced as `Outcome.versionMismatch` (terminal — gap G5).
///
/// TLS trust is TOFU cert-pinning, not CA validation: the session's
/// `TofuPinningDelegate` hands the peer cert to the composition root's
/// `PinVerifier`, which pins on first contact and aborts on mismatch — the
/// classifier then reports `.unreachable`, exactly like a dropped connection.
final class PairingClient {

    private struct Request: Encodable {
        let deviceId: String
        let deviceName: String
        let pin: String
        let clientPin: String
        let protocolVersion: Int
    }

    /// Classification of a `PairResponse` — the manager fans this out to an
    /// error banner, the PIN dialog, the approval poll, or the openSession
    /// path. Mirrors dish-linux `PairingClient::Outcome` plus the protocol-1
    /// arms.
    enum Outcome: Equatable {
        case success(sharedKeyHex: String)
        /// Path B accepted: poll `/api/pair/status` for the operator's decision.
        case pendingApproval
        case authRequired
        /// 409 — client/server protocol skew. TERMINAL: stop retrying,
        /// tell the user to update (contract §Versioning).
        case versionMismatch
        case unreachable(String)
    }

    /// Pure classifier. Driven only by fields on the response so it's
    /// trivially unit-testable.
    static func classify(_ response: PairResponse) -> Outcome {
        // Same 64-hex gate as the path-B poll: a malformed key must never
        // classify as success and get persisted.
        if response.ok, let key = response.sharedKey, isSharedKeyHex(key) {
            return .success(sharedKeyHex: key)
        }
        if response.httpStatus == 409 {
            return .versionMismatch
        }
        if response.pending {
            return .pendingApproval
        }
        if response.reachable {
            return .authRequired
        }
        return .unreachable(response.error ?? "Server unreachable")
    }

    /// Classification of one `/api/pair/status` poll. Ports dish-android
    /// `PairingApproval.Status` — approved only when the satellite both says
    /// so AND hands back a full 32-byte (64-hex) key, so a malformed reply
    /// can never be mistaken for a usable session key.
    enum ApprovalStatus: Equatable {
        case approved(sharedKeyHex: String)
        case pending
        /// Denied, expired, consumed, or an unparseable reply: stop polling.
        case declined
    }

    static func classifyStatus(_ response: PairStatusResponse) -> ApprovalStatus {
        switch response.status {
        case "approved":
            guard let key = response.sharedKey, isSharedKeyHex(key) else { return .declined }
            return .approved(sharedKeyHex: key)
        case "pending":
            return .pending
        default:
            return .declined
        }
    }

    /// Path-B client PIN: four digits, matching the satellite's own PIN
    /// format so the two screens read identically when the operator compares
    /// them. The generator is injectable so tests can pin the shape.
    static func generateClientPin(using generator: inout some RandomNumberGenerator) -> String {
        (0 ..< clientPinDigits).map { _ in String(Int.random(in: 0 ... 9, using: &generator)) }.joined()
    }

    static func generateClientPin() -> String {
        var generator = SystemRandomNumberGenerator()
        return generateClientPin(using: &generator)
    }

    private static let clientPinDigits = 4

    /// Require the hex alphabet, not just the length: a 64-char non-hex key
    /// would otherwise decode to garbage downstream in `hexToBytes`.
    static func isSharedKeyHex(_ key: String) -> Bool {
        key.count == 64 && key.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }
    }

    // MARK: - Transport

    private let session: URLSession

    /// `pinVerifier` composes the TOFU verdict ladder against the pin
    /// registry (see `WifiConnectionManager.makePinVerifier`).
    init(pinVerifier: @escaping PinVerifier) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        session = URLSession(
            configuration: cfg,
            delegate: TofuPinningDelegate(verifier: pinVerifier),
            delegateQueue: nil
        )
    }

    deinit {
        // URLSession retains its delegate until invalidated.
        session.finishTasksAndInvalidate()
    }

    /// `POST /api/pair`. Exactly one of `pin` / `clientPin` should be
    /// non-empty (both empty = the probe legacy callers used; the protocol-1
    /// server answers 400 "pairing required", classified `.authRequired`).
    /// `reachable` is true iff a JSON body arrived — every network-level
    /// failure path returns `reachable = false` so the caller can surface
    /// "Server unreachable — has it moved networks?" instead of trapping the
    /// user behind a PIN prompt they can't satisfy.
    func pair(
        ip: String,
        port: Int,
        deviceId: String,
        deviceName: String,
        pin: String,
        clientPin: String = ""
    ) async -> PairResponse {
        guard let url = URL(string: "https://\(ip):\(port)/api/pair") else {
            return PairResponse(ok: false, error: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(Request(
            deviceId: deviceId,
            deviceName: deviceName,
            pin: pin,
            clientPin: clientPin,
            protocolVersion: ProtocolConstants.protocolVersion
        )) else {
            return PairResponse(ok: false, error: "encode failed")
        }
        req.httpBody = body

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard !data.isEmpty, var parsed = try? JSONDecoder().decode(PairResponse.self, from: data) else {
                return PairResponse(ok: false, error: "malformed response", httpStatus: status)
            }
            parsed.httpStatus = status
            parsed.reachable = true
            return parsed
        } catch {
            // Network-level failure: connect refused, timeout, DNS, TLS
            // (including a TOFU mismatch abort). `reachable` stays false.
            return PairResponse(ok: false, error: error.localizedDescription)
        }
    }

    /// `GET /api/pair/status?deviceId=…` — the path-B poll. Unauthenticated
    /// (it exists to bootstrap trust); the staged key is handed back exactly
    /// once on approval.
    func pairStatus(ip: String, port: Int, deviceId: String) async -> PairStatusResponse {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = ip
        comps.port = port
        comps.path = "/api/pair/status"
        comps.queryItems = [URLQueryItem(name: "deviceId", value: deviceId)]
        guard let url = comps.url else { return PairStatusResponse() }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard !data.isEmpty,
                  var parsed = try? JSONDecoder().decode(PairStatusResponse.self, from: data) else
            {
                var failed = PairStatusResponse()
                failed.httpStatus = status
                return failed
            }
            parsed.httpStatus = status
            parsed.reachable = true
            return parsed
        } catch {
            return PairStatusResponse()
        }
    }
}
