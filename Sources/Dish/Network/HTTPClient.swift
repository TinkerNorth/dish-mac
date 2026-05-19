// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// `URLSessionDelegate` that unconditionally accepts the server's TLS trust.
///
/// The Satellite ships a SELF-SIGNED certificate, so the platform trust
/// evaluation would otherwise reject every connection. This is a deliberate,
/// approved project decision — the dish accepts the certificate WITHOUT
/// verification or pinning, equivalent to `curl --insecure`. It disables both
/// certificate-chain and hostname validation by handing back a credential
/// built straight from the offered `SecTrust`.
final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            // Not a server-trust challenge — let the system handle it.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Accept whatever certificate the satellite offered, unconditionally.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Thin wrapper around `URLSession` for the Satellite connection API.
/// The server speaks HTTPS/1.1 (TLS, self-signed cert) on `:9443`. These calls
/// are blocking and expected to run on a background actor / queue.
enum HTTPClient {

    /// Retained for the lifetime of the session; `URLSession` only holds a
    /// weak-ish reference and the delegate must outlive in-flight requests.
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

    /// `POST /api/connections` — server returns `{connectionId, token, ...}`.
    static func connect(ip: String, port: Int, deviceId: String) async -> ConnectResponse {
        guard let url = URL(string: "https://\(ip):\(port)/api/connections") else {
            return ConnectResponse(error: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let deviceId: String }
        req.httpBody = try? JSONEncoder().encode(Body(deviceId: deviceId))
        return await perform(req)
    }

    /// `DELETE /api/connections/:id` — server drops the connection and all its
    /// attached controllers.
    @discardableResult
    static func disconnect(
        ip: String,
        port: Int,
        connectionId: String,
        deviceId: String
    ) async -> ConnectResponse {
        guard let url = URL(string: "https://\(ip):\(port)/api/connections/\(connectionId)") else {
            return ConnectResponse(error: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let deviceId: String }
        req.httpBody = try? JSONEncoder().encode(Body(deviceId: deviceId))
        return await perform(req)
    }

    private static func perform(_ req: URLRequest) async -> ConnectResponse {
        do {
            let (data, _) = try await session.data(for: req)
            if let parsed = try? JSONDecoder().decode(ConnectResponse.self, from: data) {
                return parsed
            }
            return ConnectResponse(error: "malformed")
        } catch {
            return ConnectResponse(error: error.localizedDescription)
        }
    }
}
