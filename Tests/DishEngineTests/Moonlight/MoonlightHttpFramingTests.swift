// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The text of one exchange, without a socket: the head the dish writes and
/// the three ways a host's body is framed.
final class MoonlightHttpFramingTests: XCTestCase {

    func testTheRequestHeadNamesTheHostWithItsPortAndAsksForTheClose() {
        let request = MoonlightHttpRequest(host: "192.168.1.20", port: 47989, tls: false, pathAndQuery: "/serverinfo?uniqueid=u&uuid=n")
        let head = String(bytes: MoonlightHttpFraming.requestHead(request), encoding: .utf8)
        XCTAssertEqual(
            head,
            "GET /serverinfo?uniqueid=u&uuid=n HTTP/1.1\r\nHost: 192.168.1.20:47989\r\n"
                + "User-Agent: Dish/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        )
        let scheme = MoonlightHttpRequest(host: "pc", port: 80, tls: false, pathAndQuery: "/")
        XCTAssertTrue(
            String(bytes: MoonlightHttpFraming.requestHead(scheme), encoding: .utf8)?.contains("Host: pc\r\n") ?? false,
            "the scheme default rides bare"
        )
    }

    func testTheHeadParsesInEitherLineEndingWithLowercaseNames() throws {
        let crlf = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Thing: a b \r\n\r\nhello".utf8)
        let head = try XCTUnwrap(MoonlightHttpFraming.parseHead(crlf))
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.headers["content-length"], "5")
        XCTAssertEqual(head.headers["x-thing"], "a b")
        XCTAssertEqual(head.bodyStart, crlf.count - 5)
        let bare = try XCTUnwrap(MoonlightHttpFraming.parseHead(Data("HTTP/1.0 404 Not Found\nContent-Length: 0\n\n".utf8)))
        XCTAssertEqual(bare.status, 404)
        XCTAssertNil(MoonlightHttpFraming.parseHead(Data("HTTP/1.1 200 OK\r\nContent-Length".utf8)), "not ended yet")
        XCTAssertNil(MoonlightHttpFraming.parseHead(Data("RTSP/1.0 200 OK\r\n\r\n".utf8)), "not HTTP")
        XCTAssertNil(MoonlightHttpFraming.parseHead(Data("HTTP/1.1 999 Odd\r\n\r\n".utf8)))
        XCTAssertFalse(MoonlightHttpFraming.headOverflowed(Data(repeating: 0x41, count: 100)))
        XCTAssertTrue(MoonlightHttpFraming.headOverflowed(Data(repeating: 0x41, count: MoonlightHttpFraming.maxHeadBytes)))
    }

    func testFramingPrecedenceAndTheThreeBodies() {
        let chunkedHead = MoonlightHttpFraming.Head(
            status: 200,
            headers: ["transfer-encoding": "Chunked", "content-length": "99"],
            bodyStart: 0
        )
        XCTAssertEqual(MoonlightHttpFraming.framing(chunkedHead), .chunked, "chunked wins")
        XCTAssertEqual(
            MoonlightHttpFraming.framing(.init(status: 200, headers: ["content-length": "12"], bodyStart: 0)),
            .contentLength(12)
        )
        XCTAssertEqual(MoonlightHttpFraming.framing(.init(status: 200, headers: [:], bodyStart: 0)), .untilClose)
        let counted = MoonlightHttpFraming.body(.contentLength(5), from: Data("hel".utf8), closed: false)
        XCTAssertFalse(counted.complete)
        assertFramed(
            MoonlightHttpFraming.body(.contentLength(5), from: Data("hello!".utf8), closed: false),
            Data("hello".utf8),
            complete: true
        )
        assertFramed(
            MoonlightHttpFraming.body(.contentLength(5), from: Data("hel".utf8), closed: true),
            Data("hel".utf8),
            complete: true,
            "cut short: what arrived"
        )
        XCTAssertEqual(MoonlightHttpFraming.body(.untilClose, from: Data("abc".utf8), closed: false).complete, false)
        assertFramed(MoonlightHttpFraming.body(.untilClose, from: Data("abc".utf8), closed: true), Data("abc".utf8), complete: true)
    }

    private func assertFramed(
        _ framed: (body: Data, complete: Bool),
        _ body: Data,
        complete: Bool,
        _ message: String = "",
        line: UInt = #line
    ) {
        XCTAssertEqual(framed.body, body, message, line: line)
        XCTAssertEqual(framed.complete, complete, message, line: line)
    }

    func testChunkedBodiesWithExtensionsAndCutsShort() {
        let whole = Data("5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        assertFramed(MoonlightHttpFraming.decodeChunked(whole, closed: false), Data("hello world".utf8), complete: true)
        let partial = Data("5\r\nhel".utf8)
        assertFramed(MoonlightHttpFraming.decodeChunked(partial, closed: false), Data("hel".utf8), complete: false, "waiting on the rest")
        XCTAssertEqual(MoonlightHttpFraming.decodeChunked(partial, closed: true).complete, true, "the close ends it with what arrived")
        assertFramed(
            MoonlightHttpFraming.decodeChunked(Data("zz\r\n".utf8), closed: false),
            Data(),
            complete: true,
            "a size that is not hex ends the body"
        )
        XCTAssertEqual(MoonlightHttpFraming.decodeChunked(Data("5".utf8), closed: false).complete, false, "no line yet")
    }
}
