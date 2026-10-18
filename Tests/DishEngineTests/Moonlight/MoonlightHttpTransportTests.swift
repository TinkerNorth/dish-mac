// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Security
import XCTest
@testable import DishEngine

/// One connection per request against a loopback host: the three body
/// framings, the ways a host fails to answer, and mutual TLS with the dish's
/// certificate presented and the host's leaf judged inside the handshake.
final class MoonlightHttpTransportTests: XCTestCase {

    private var server: MoonlightLoopbackServer!
    private let transport = MoonlightHttpTransport()

    override func setUp() {
        super.setUp()
        server = MoonlightLoopbackServer()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    private func request(_ path: String, tls: Bool = false) -> MoonlightHttpRequest {
        MoonlightHttpRequest(host: "127.0.0.1", port: server.port, tls: tls, pathAndQuery: path)
    }

    func testCountedChunkedAndClosedBodiesArriveWhole() async throws {
        server.answer("/counted", status: 200, body: "<root status_code=\"200\"/>")
        server.answer(
            "/chunked",
            .bytes(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n".utf8))
        )
        server.answer("/closed", .bytes(Data("HTTP/1.1 401 Unauthorized\r\n\r\nno length, read to the close".utf8)))
        _ = try server.start()
        let counted = await transport.get(request("/counted?uniqueid=u"), tls: nil, timeout: 5)
        XCTAssertEqual(counted, MoonlightHttpReply(status: 200, body: "<root status_code=\"200\"/>"))
        let chunked = await transport.get(request("/chunked"), tls: nil, timeout: 5)
        XCTAssertEqual(chunked, MoonlightHttpReply(status: 200, body: "hello!"))
        let closed = await transport.get(request("/closed"), tls: nil, timeout: 5)
        XCTAssertEqual(closed, MoonlightHttpReply(status: 401, body: "no length, read to the close"))
        XCTAssertEqual(server.requests, ["/counted?uniqueid=u", "/chunked", "/closed"], "the query rides the request line")
    }

    func testAHostThatNeverAnswersHangsUpOrIsNotThereIsUnreachable() async throws {
        server.answer("/slow", .slow)
        server.answer("/hangup", .closeWithoutAnswer)
        let port = try server.start()
        let hungUp = await transport.get(request("/hangup"), tls: nil, timeout: 5)
        XCTAssertEqual(hungUp, .unreachable)
        let slow = await transport.get(request("/slow"), tls: nil, timeout: 0.5)
        XCTAssertEqual(slow, .unreachable, "the deadline, not the host, ends it")
        server.stop()
        let started = Date()
        let gone = await transport.get(
            MoonlightHttpRequest(host: "127.0.0.1", port: port, tls: false, pathAndQuery: "/counted"),
            tls: nil,
            timeout: 2
        )
        XCTAssertEqual(gone, .unreachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a refused connect fails at once, not at the deadline")
    }

    func testMutualTlsPresentsTheDishsCertificateAndJudgesTheHostsLeaf() async throws {
        let hostIdentity = try FakeSatelliteCertificateMint.mint(commonName: "moonlight-host")
        guard let hostSecIdentity = hostIdentity.secIdentity(), let keychain = FakeSatelliteThrowawayKeychain.shared,
              let client = MoonlightIdentityStore.loadOrCreate(keychain: keychain), let clientSecIdentity = client.secIdentity() else
        {
            throw XCTSkip("no keychain-backed identities on this runner")
        }
        server.answer("/serverinfo", status: 200, body: "<root><PairStatus>1</PairStatus></root>")
        _ = try server.start(identity: hostSecIdentity, requireClientCertificate: true)
        let seen = LockedBox<[Data]>([])
        let tls = MoonlightTls(identity: clientSecIdentity) { leaf in
            seen.mutate { $0.append(leaf) }
            return leaf == hostIdentity.certificateDER
        }
        let first = await transport.get(request("/serverinfo", tls: true), tls: tls, timeout: 10)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(seen.get(), [hostIdentity.certificateDER], "the host's leaf was judged once")
        XCTAssertEqual(server.clientCertificates, [client.certificateDER], "the host saw the dish's certificate")
        let second = await transport.get(request("/serverinfo", tls: true), tls: tls, timeout: 10)
        XCTAssertEqual(second.status, 200, "a second full handshake, no resumption")
        XCTAssertEqual(server.clientCertificates.count, 2)
    }

    func testARefusedLeafNeverSeesARequest() async throws {
        let hostIdentity = try FakeSatelliteCertificateMint.mint(commonName: "imposter")
        guard let hostSecIdentity = hostIdentity.secIdentity() else { throw XCTSkip("no keychain-backed identity on this runner") }
        server.answer("/serverinfo", status: 200, body: "<root/>")
        _ = try server.start(identity: hostSecIdentity)
        let tls = MoonlightTls(identity: nil) { _ in false }
        let refused = await transport.get(request("/serverinfo", tls: true), tls: tls, timeout: 5)
        XCTAssertEqual(refused, .unreachable)
        XCTAssertEqual(server.requests, [], "the handshake was cancelled before any request bytes")
    }
}
