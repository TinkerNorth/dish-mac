// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Thin wrapper around `URLSession` for the Satellite connection API.
/// The server speaks plain HTTP/1.1 on `:9877`. These calls are blocking and
/// expected to run on a background actor / queue.
enum HTTPClient {

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// `POST /api/connections` — server returns `{connectionId, token, ...}`.
    static func connect(ip: String, port: Int, deviceId: String) async -> ConnectResponse {
        guard let url = URL(string: "http://\(ip):\(port)/api/connections") else {
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
        guard let url = URL(string: "http://\(ip):\(port)/api/connections/\(connectionId)") else {
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
