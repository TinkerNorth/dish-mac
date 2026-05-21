// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Blocking pair handshake with a Satellite server. Mirrors
/// `satellite_jni.cpp :: pair`. Performs an HTTPS `POST /api/pair` and parses
/// the server's JSON reply.
///
/// The transport changed: pairing used to be a bespoke raw-TCP JSON-line
/// protocol on its own port. It is now a plain HTTPS POST on the client API
/// server (`:9443`). The request/response JSON shapes are unchanged.
enum PairingClient {

    struct Request: Encodable {
        let deviceId: String
        let deviceName: String
        let pin: String
    }

    /// Dedicated `URLSession` for pairing. Uses the same self-signed-accepting
    /// trust delegate as `HTTPClient` — the satellite's certificate is accepted
    /// WITHOUT verification or pinning (`curl --insecure` equivalent), a
    /// deliberate, approved project decision.
    private static let trustDelegate = InsecureTrustDelegate()

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        return URLSession(
            configuration: cfg,
            delegate: trustDelegate,
            delegateQueue: nil
        )
    }()

    /// Classifies a `PairResponse` so callers can distinguish "server moved /
    /// went offline" (network failure) from "server refused our PIN / shared
    /// key" (auth failure). Mirrors the same distinction Android's
    /// `SatelliteConnectionManager` makes after dish-android PR #43.
    enum Outcome: Equatable {
        case success(sharedKeyHex: String)
        case authRequired
        case unreachable(String)
    }

    /// Pure classifier. Driven only by fields on the response so it's
    /// trivially unit-testable.
    static func classify(_ response: PairResponse) -> Outcome {
        if response.ok, let key = response.sharedKey, !key.isEmpty {
            return .success(sharedKeyHex: key)
        }
        if response.reachable {
            return .authRequired
        }
        return .unreachable(response.error ?? "Server unreachable")
    }

    /// Call from a background queue. Returns the parsed `PairResponse`.
    /// `reachable` is set to `true` iff we received and parsed a JSON body
    /// from the server; every network-level failure path returns `reachable
    /// = false` so the caller can surface a clean "Server unreachable —
    /// has it moved networks?" message instead of trapping the user behind
    /// a PIN prompt they can't satisfy.
    ///
    /// Synchronous by contract — drives a `DispatchSemaphore` around the async
    /// `URLSession` call so existing callers keep working unchanged.
    static func pair(
        ip: String,
        port: Int,
        deviceId: String,
        deviceName: String,
        pin: String
    ) -> PairResponse {
        guard let url = URL(string: "https://\(ip):\(port)/api/pair") else {
            return PairResponse(ok: false, error: "bad url")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(
            Request(deviceId: deviceId, deviceName: deviceName, pin: pin)
        ) else {
            return PairResponse(ok: false, error: "encode failed")
        }
        req.httpBody = body

        var result = PairResponse(ok: false, error: "no response")
        let done = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: req) { data, _, error in
            defer { done.signal() }
            if let error {
                // Network-level failure: connect refused, timeout, DNS, TLS.
                // `reachable` stays false so the caller treats it as offline.
                result = PairResponse(ok: false, error: error.localizedDescription)
                return
            }
            guard let data, !data.isEmpty else {
                result = PairResponse(ok: false, error: "no response")
                return
            }
            // The server always returns HTTP 200 with a JSON body; even
            // `ok=false` counts as a successful round-trip, hence reachable.
            if var parsed = try? JSONDecoder().decode(PairResponse.self, from: data) {
                parsed.reachable = true
                result = parsed
            } else {
                result = PairResponse(ok: false, error: "malformed response")
            }
        }
        task.resume()
        done.wait()
        return result
    }
}
