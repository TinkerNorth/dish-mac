// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The handshake against a loopback host that answers one message per
/// connection and hangs up: every step in order, the session echoed once
/// named, the ports and the token read back, and the ways it fails.
final class MoonlightRtspClientTests: XCTestCase {

    private var host: MoonlightLoopbackRtspHost!

    override func setUp() {
        super.setUp()
        host = MoonlightLoopbackRtspHost.sunshineLike()
    }

    override func tearDown() {
        host.stop()
        super.tearDown()
    }

    func testTheWholeHandshakeNegotiatesThePortsTheTokenAndThePayload() async throws {
        let port = try host.start()
        let client = MoonlightRtspClient(address: "127.0.0.1", port: port)
        let ports = await client.handshake()
        XCTAssertEqual(
            ports,
            MoonlightStreamPorts(
                controlPort: 47999,
                videoPort: 47998,
                audioPort: 48000,
                connectData: 4_270_471_497,
                pingPayload: "9A615601970AEC19"
            )
        )
        let lines = host.requests.map { $0.split(separator: "\r\n").first.map(String.init) ?? "" }
        let expected = [
            "OPTIONS rtsp://127.0.0.1:\(port) RTSP/1.0",
            "DESCRIBE rtsp://127.0.0.1:\(port) RTSP/1.0",
            "SETUP streamid=audio/0/0 RTSP/1.0",
            "SETUP streamid=video/0/0 RTSP/1.0",
            "SETUP streamid=control/0/0 RTSP/1.0",
            "ANNOUNCE streamid=control/13/0 RTSP/1.0",
            "PLAY rtsp://127.0.0.1:\(port) RTSP/1.0"
        ]
        XCTAssertEqual(lines, expected, "seven connections, the steps' order")
        XCTAssertEqual(host.requests.map { $0.contains("CSeq: ") }, Array(repeating: true, count: 7))
        XCTAssertFalse(host.requests[2].contains("Session:"), "the first SETUP has no session yet")
        XCTAssertTrue(host.requests[3].contains("Session: DEADBEEFCAFE\r\n"), "echoed from the second SETUP on, without the timeout")
        XCTAssertTrue(host.requests[6].contains("Session: DEADBEEFCAFE\r\n"))
        XCTAssertTrue(host.requests[5].contains("Content-length: "), "the ANNOUNCE carries the SDP")
        XCTAssertTrue(host.requests[5].hasSuffix("a=x-ss-general.encryptionEnabled:0\r\nt=0 0\r\n"))
        XCTAssertEqual(
            host.requests.map { $0.components(separatedBy: "CSeq: ").last?.prefix(1) ?? "" },
            ["1", "2", "3", "4", "5", "6", "7"]
        )
    }

    func testARefusedStepAHangUpAndAnAbsentHostEndTheHandshake() async throws {
        host.reply("ANNOUNCE", "RTSP/1.0 400 Bad Request\r\nCSeq: 6\r\n\r\n")
        let port = try host.start()
        let refused = await MoonlightRtspClient(address: "127.0.0.1", port: port).handshake()
        XCTAssertNil(refused)
        XCTAssertEqual(host.requests.count, 6, "it stopped at the ANNOUNCE")
        host.stop()
        let hangingUp = MoonlightLoopbackRtspHost.sunshineLike()
        hangingUp.hangUp(on: "DESCRIBE")
        let port2 = try hangingUp.start()
        defer { hangingUp.stop() }
        let hungUp = await MoonlightRtspClient(address: "127.0.0.1", port: port2).handshake()
        XCTAssertNil(hungUp)
        XCTAssertEqual(hangingUp.requests.count, 2)
        let started = Date()
        let gone = await MoonlightRtspClient(address: "127.0.0.1", port: port).handshake()
        XCTAssertNil(gone, "nothing listens there any more")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a refused connect fails at once, not at the deadline")
    }

    func testStepsCanBePerformedOneAtATimeAndTheControlPortIsRequired() async throws {
        host.reply("SETUP streamid=control", "RTSP/1.0 200 OK\r\nCSeq: 5\r\nSession: DEADBEEFCAFE\r\n\r\n")
        let port = try host.start()
        let client = MoonlightRtspClient(address: "127.0.0.1", port: port)
        for step in MoonlightRtspStep.allCases {
            let ok = await client.perform(step)
            XCTAssertTrue(ok, "\(step)")
        }
        XCTAssertNil(client.negotiated, "no control port, no stream")
    }
}
