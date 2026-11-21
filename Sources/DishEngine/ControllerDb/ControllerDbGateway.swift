// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The website's controller data over HTTPS: the manifest with
// `If-None-Match`, then each file it names. No query, no identifier, the
// platform's default user agent, nothing in the request but the path.

import DishCore
import Foundation

/// The check's one IO boundary; a test hands in a recorder.
protocol ControllerDbGateway: AnyObject {
    func fetchManifest(etag: String?) async -> ManifestReply
    /// Nil for no answer or any status but 200.
    func fetchFile(_ path: String) async -> Data?
}

/// Answers nothing and sends nothing: a composition root built outside the app.
final class OfflineControllerDbGateway: ControllerDbGateway {
    func fetchManifest(etag _: String?) async -> ManifestReply {
        .unreachable
    }

    func fetchFile(_: String) async -> Data? {
        nil
    }
}

final class ControllerDbHTTPClient: ControllerDbGateway {
    private let session: URLSession
    private let base: URL

    init(base: URL, session: URLSession = ControllerDbHTTPClient.ephemeral()) {
        self.base = base
        self.session = session
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// No cookies, no cache of its own: the ETag is ours to send.
    static func ephemeral() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func fetchManifest(etag: String?) async -> ManifestReply {
        var request = URLRequest(url: base.appendingPathComponent(ControllerDbFiles.manifest))
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        return manifestReply(status: http.statusCode, body: data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    func fetchFile(_ path: String) async -> Data? {
        let request = URLRequest(url: base.appendingPathComponent(path))
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
    }
}

/// 304 is "nothing new", 200 a manifest, anything else no answer.
func manifestReply(status: Int, body: Data, etag: String?) -> ManifestReply {
    switch status {
    case 304: .notModified
    case 200: .body(body, etag: etag)
    default: .unreachable
    }
}
