// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Minimal HTTP/1.1 request parsing + response serialization for the fake.
enum FakeSatelliteHttp {

    struct Request {
        let method: String
        let plainPath: String
        let query: [String: String]
        let headers: [String: String] // keys lowercased
        let body: Data
    }

    struct Response {
        let status: Int
        var headers: [(String, String)]
        let body: Data
    }

    /// Parses one complete request off the front of `buffer`; nil when more
    /// bytes are needed. Returns the request and the consumed byte count.
    static func parseRequest(_ buffer: Data) -> (Request, Int)? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(bytes: buffer[buffer.startIndex ..< headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }
        let body = Data(buffer[bodyStart ..< buffer.index(bodyStart, offsetBy: contentLength)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + contentLength
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        let plainPath = String(pathAndQuery[0])
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let sides = pair.split(separator: "=", maxSplits: 1)
                guard sides.count == 2 else { continue }
                let key = String(sides[0]).removingPercentEncoding ?? String(sides[0])
                query[key] = String(sides[1]).removingPercentEncoding ?? String(sides[1])
            }
        }
        return (Request(method: method, plainPath: plainPath, query: query, headers: headers, body: body), consumed)
    }

    static func serialize(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    static func json(_ status: Int, _ object: [String: Any]) -> Response {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return Response(status: status, headers: [("Content-Type", "application/json")], body: body)
    }

    static func json(_ status: Int, raw: String) -> Response {
        Response(status: status, headers: [("Content-Type", "application/json")], body: Data(raw.utf8))
    }

    static func parseJSON(_ data: Data) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
