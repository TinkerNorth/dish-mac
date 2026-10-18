// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The text of one HTTP/1.1 exchange with a Moonlight host, pure so it is
// tested without a socket: the request head the transport writes, and the
// reply's head and body framing, in the precedence RFC 9112 gives it:
// chunked wins over Content-Length, and with neither the body runs to the
// close the request asked for.

import DishCore
import Foundation

enum MoonlightHttpFraming {
    static let userAgent = "Dish/1.0"
    static let maxHeadBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    struct Head: Equatable {
        var status: Int
        var headers: [String: String]
        /// Where the body starts in the buffer the head was parsed from.
        var bodyStart: Int
    }

    enum Framing: Equatable {
        case chunked
        case contentLength(Int)
        case untilClose
    }

    /// `GET`, the host with its port when it is not the scheme default, and
    /// `Connection: close` so the host drops its half once it has answered.
    static func requestHead(_ request: MoonlightHttpRequest) -> Data {
        let authority = request.port == 80 ? request.host : "\(request.host):\(request.port)"
        let lines = [
            "GET \(request.pathAndQuery) HTTP/1.1",
            "Host: \(authority)",
            "User-Agent: \(userAgent)",
            "Accept: */*",
            "Connection: close"
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// The reply's head once the blank line has arrived; nil while it has
    /// not. CRLF or bare LF both end a line; header names read lowercase.
    static func parseHead(_ buffer: Data) -> Head? {
        guard let end = headEnd(buffer) else { return nil }
        guard let text = String(bytes: buffer.prefix(end.headLength), encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty, let status = parseStatus(lines.removeFirst()) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return Head(status: status, headers: headers, bodyStart: end.bodyStart)
    }

    /// Whether the head has ended within the size a host is allowed.
    static func headOverflowed(_ buffer: Data) -> Bool {
        headEnd(buffer) == nil && buffer.count >= maxHeadBytes
    }

    static func framing(_ head: Head) -> Framing {
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .chunked }
        if let length = head.headers["content-length"].flatMap(Int.init) { return .contentLength(max(0, min(length, maxBodyBytes))) }
        return .untilClose
    }

    /// The body so far and whether it is complete, for the bytes after the head.
    static func body(_ framing: Framing, from bytes: Data, closed: Bool) -> (body: Data, complete: Bool) {
        switch framing {
        case let .contentLength(length):
            (bytes.prefix(length), bytes.count >= length || closed)
        case .untilClose:
            (bytes.prefix(maxBodyBytes), closed || bytes.count >= maxBodyBytes)
        case .chunked:
            decodeChunked(bytes, closed: closed)
        }
    }

    /// Chunk size lines in hex (an extension after `;` ignored), a chunk,
    /// its CRLF, down to the zero chunk; a body cut short is what arrived.
    static func decodeChunked(_ bytes: Data, closed: Bool) -> (body: Data, complete: Bool) {
        var out = Data()
        var cursor = bytes.startIndex
        while out.count < maxBodyBytes {
            guard let lineEnd = bytes[cursor...].firstIndex(of: 0x0A) else { return (out, closed) }
            let line = String(bytes: bytes[cursor ..< lineEnd], encoding: .utf8) ?? ""
            let sizeText = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard let size = Int(sizeText, radix: 16) else { return (out, true) }
            if size == 0 { return (out, true) }
            let chunkStart = bytes.index(after: lineEnd)
            guard bytes.distance(from: chunkStart, to: bytes.endIndex) >= size + 2 else { return (
                out + bytes[chunkStart...].prefix(size),
                closed
            ) }
            out.append(bytes[chunkStart ..< chunkStart + size])
            cursor = chunkStart + size + 2
        }
        return (out, true)
    }

    private static func headEnd(_ buffer: Data) -> (headLength: Int, bodyStart: Int)? {
        if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) { return (range.lowerBound, range.upperBound) }
        if let range = buffer.range(of: Data([0x0A, 0x0A])) { return (range.lowerBound, range.upperBound) }
        return nil
    }

    /// `HTTP/1.1 200 OK` → 200; anything that is not a status line → nil.
    private static func parseStatus(_ line: String) -> Int? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]), (100 ... 599).contains(status) else { return nil }
        return status
    }
}
