// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The HTTP requests a Moonlight host answers (Wolf rest/servers.cpp routes),
// as path and query only: the engine's own HTTP/1.1 client opens the socket,
// plain on the HTTP port or mutual TLS on the HTTPS port. Ports are never
// assumed here; the caller passes what /serverinfo said. Every request
// carries the client's `uniqueid` and, as real clients do, a `uuid` nonce
// so no cache in between answers twice.

import Foundation

/// One request: where, how, and what.
public struct MoonlightHttpRequest: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var tls: Bool
    public var pathAndQuery: String

    public init(host: String, port: UInt16, tls: Bool, pathAndQuery: String) {
        self.host = host
        self.port = port
        self.tls = tls
        self.pathAndQuery = pathAndQuery
    }
}

/// A host as the requests need it.
public struct MoonlightEndpoint: Equatable, Sendable {
    public var address: String
    public var httpPort: UInt16
    public var httpsPort: UInt16

    public init(address: String, httpPort: UInt16 = MoonlightProtocol.httpPort, httpsPort: UInt16 = MoonlightProtocol.httpsPort) {
        self.address = address
        self.httpPort = httpPort
        self.httpsPort = httpsPort
    }
}

/// What a /launch asks for: the lowest stream the protocol expresses, since
/// the dish negotiates the streams and then discards them.
public struct MoonlightLaunchRequest: Equatable, Sendable {
    public static let mode = "1280x720x30"
    /// Stereo: channel mask 0x3 in the high half, two channels in the low.
    public static let surroundAudioInfo = "196610"

    public var appId: String
    /// The 16-byte key the control stream is sealed with, minted per launch.
    public var rikey: Data
    /// Four random bytes read little-endian as a signed 32-bit number and
    /// sent in decimal, as real clients do; a host keys nothing on its sign.
    public var rikeyId: Int32

    public init(appId: String, rikey: Data, rikeyId: Int32) {
        self.appId = appId
        self.rikey = rikey
        self.rikeyId = rikeyId
    }
}

public enum MoonlightUrls {
    public static func serverInfo(_ endpoint: MoonlightEndpoint, tls: Bool, uniqueId: String, nonce: String) -> MoonlightHttpRequest {
        request(endpoint, tls: tls, path: "/serverinfo", params: [], uniqueId: uniqueId, nonce: nonce)
    }

    public static func pair(_ endpoint: MoonlightEndpoint, tls: Bool, params: [(String, String)], nonce: String) -> MoonlightHttpRequest {
        MoonlightHttpRequest(
            host: endpoint.address,
            port: tls ? endpoint.httpsPort : endpoint.httpPort,
            tls: tls,
            pathAndQuery: "/pair?" + query(params + [("uuid", nonce)])
        )
    }

    public static func appList(_ endpoint: MoonlightEndpoint, uniqueId: String, nonce: String) -> MoonlightHttpRequest {
        request(endpoint, tls: true, path: "/applist", params: [], uniqueId: uniqueId, nonce: nonce)
    }

    public static func launch(
        _ endpoint: MoonlightEndpoint,
        uniqueId: String,
        launch: MoonlightLaunchRequest,
        nonce: String
    ) -> MoonlightHttpRequest {
        let params = [
            ("appid", launch.appId),
            ("mode", MoonlightLaunchRequest.mode),
            ("additionalStates", "1"),
            ("sops", "0"),
            ("rikey", hexEncodeLower(launch.rikey)),
            ("rikeyid", String(launch.rikeyId)),
            ("localAudioPlayMode", "1"),
            ("surroundAudioInfo", MoonlightLaunchRequest.surroundAudioInfo)
        ]
        return request(endpoint, tls: true, path: "/launch", params: params, uniqueId: uniqueId, nonce: nonce)
    }

    /// Joining the session the host already runs for this client: the key
    /// and the stereo ask, nothing about the app.
    public static func resume(
        _ endpoint: MoonlightEndpoint,
        uniqueId: String,
        launch: MoonlightLaunchRequest,
        nonce: String
    ) -> MoonlightHttpRequest {
        let params = [
            ("rikey", hexEncodeLower(launch.rikey)),
            ("rikeyid", String(launch.rikeyId)),
            ("surroundAudioInfo", MoonlightLaunchRequest.surroundAudioInfo)
        ]
        return request(endpoint, tls: true, path: "/resume", params: params, uniqueId: uniqueId, nonce: nonce)
    }

    public static func cancel(_ endpoint: MoonlightEndpoint, uniqueId: String, nonce: String) -> MoonlightHttpRequest {
        request(endpoint, tls: true, path: "/cancel", params: [], uniqueId: uniqueId, nonce: nonce)
    }

    /// `application/x-www-form-urlencoded`: letters, digits and `.-*_` as
    /// they are, a space as `+`, everything else as percent-encoded UTF-8.
    public static func formEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x2E, 0x2D, 0x2A, 0x5F:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    static func query(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
    }

    private static func request(
        _ endpoint: MoonlightEndpoint, tls: Bool, path: String, params: [(String, String)], uniqueId: String, nonce: String
    ) -> MoonlightHttpRequest {
        let all = [("uniqueid", uniqueId)] + params + [("uuid", nonce)]
        return MoonlightHttpRequest(
            host: endpoint.address,
            port: tls ? endpoint.httpsPort : endpoint.httpPort,
            tls: tls,
            pathAndQuery: path + "?" + query(all)
        )
    }
}
