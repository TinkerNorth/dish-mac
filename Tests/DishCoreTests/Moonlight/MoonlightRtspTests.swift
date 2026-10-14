// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// Request text pinned exactly, since hosts parse it with a strict grammar;
/// replies parsed in both line endings hosts emit.
final class MoonlightRtspTests: XCTestCase {

    func testOptionsAndDescribe() {
        XCTAssertEqual(
            MoonlightRtsp.options(cseq: 1, target: "rtsp://192.168.1.100:48010").encode(),
            "OPTIONS rtsp://192.168.1.100:48010 RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n\r\n"
        )
        XCTAssertEqual(
            MoonlightRtsp.describe(cseq: 2, target: "rtsp://10.0.0.7:48010").encode(),
            "DESCRIBE rtsp://10.0.0.7:48010 RTSP/1.0\r\nCSeq: 2\r\nX-GS-ClientVersion: 14\r\nAccept: application/sdp\r\n\r\n"
        )
    }

    func testSetupWithAndWithoutASession() {
        XCTAssertEqual(
            MoonlightRtsp.setup(cseq: 3, streamId: "audio", sessionId: "").encode(),
            "SETUP streamid=audio/0/0 RTSP/1.0\r\nCSeq: 3\r\nX-GS-ClientVersion: 14\r\n"
                + "Transport: unicast;X-GS-ClientPort=50000-50001\r\nIf-Modified-Since: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n"
        )
        let withSession = MoonlightRtsp.setup(cseq: 4, streamId: "control", sessionId: "DEADBEEFCAFE").encode()
        XCTAssertTrue(withSession
            .hasPrefix("SETUP streamid=control/0/0 RTSP/1.0\r\nCSeq: 4\r\nX-GS-ClientVersion: 14\r\nSession: DEADBEEFCAFE\r\n"))
    }

    func testAnnounceCarriesTheSdpAfterTheBlankLineAndPlayNamesTheSession() {
        let sdp = MoonlightRtsp.announceSdp(MoonlightStreamConfig())
        let announce = MoonlightRtsp.announce(cseq: 6, sessionId: "DEADBEEFCAFE", sdp: sdp).encode()
        XCTAssertTrue(announce
            .hasPrefix("ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\nX-GS-ClientVersion: 14\r\nSession: DEADBEEFCAFE\r\n"))
        XCTAssertTrue(announce.contains("Content-type: application/sdp\r\nContent-length: \(sdp.utf8.count)\r\n\r\nv=0\r\n"))
        XCTAssertTrue(announce.hasSuffix(sdp))
        XCTAssertEqual(
            MoonlightRtsp.play(cseq: 7, target: "rtsp://10.0.0.7:48010", sessionId: "DEADBEEFCAFE").encode(),
            "PLAY rtsp://10.0.0.7:48010 RTSP/1.0\r\nCSeq: 7\r\nX-GS-ClientVersion: 14\r\nSession: DEADBEEFCAFE\r\n\r\n"
        )
    }

    /// The whole set: a lookup that misses is fatal on a live host.
    func testTheSdpIsTheWholeAttributeSet() {
        let lines = MoonlightRtsp.announceSdp(MoonlightStreamConfig()).split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.count, 36)
        XCTAssertEqual(lines.prefix(3), ["v=0", "o=android 0 14 IN IPv4 0.0.0.0", "s=NVIDIA Streaming Client"])
        XCTAssertEqual(lines.last, "t=0 0")
        for pinned in [
            "a=x-nv-video[0].clientViewportWd:1280", "a=x-nv-video[0].clientViewportHt:720", "a=x-nv-video[0].maxFPS:30",
            "a=x-nv-video[0].clientRefreshRateX100:3000", "a=x-nv-vqos[0].bw.minimumBitrateKbps:500",
            "a=x-nv-vqos[0].bw.maximumBitrateKbps:500",
            "a=x-nv-audio.surround.numChannels:2", "a=x-nv-audio.surround.channelMask:3", "a=x-nv-general.useReliableUdp:13",
            "a=x-nv-general.featureFlags:167", "a=x-ml-general.featureFlags:3", "a=x-ss-general.encryptionEnabled:0"
        ] {
            XCTAssertTrue(lines.contains(pinned), pinned)
        }
        XCTAssertFalse(MoonlightRtsp.announceSdp(MoonlightStreamConfig()).contains("\n\n"), "CRLF, one attribute per line")
    }

    func testResponsesParseInEitherLineEnding() throws {
        let crlf = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: DEADBEEFCAFE;timeout = 90\r\n"
            + "Transport: unicast;X-GS-ClientPort=50000-50001;server_port=48000\r\n\r\n"
        let response = try XCTUnwrap(MoonlightRtspResponse.parse(crlf))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.statusMessage, "OK")
        XCTAssertEqual(response.cseq, 3)
        XCTAssertEqual(response.serverPort(), 48000)
        XCTAssertEqual(response.sessionId(), "DEADBEEFCAFE")
        XCTAssertEqual(response.option("transport"), response.options["Transport"], "options are looked up without case")
        let bare = try XCTUnwrap(MoonlightRtspResponse.parse("RTSP/1.0 200 OK\nCSeq: 2\nContent-length: 5\n\nv=0\n"))
        XCTAssertEqual(bare.contentLength(), 5)
        XCTAssertEqual(bare.payload, "v=0\n")
    }

    func testTheConnectTokenIsReadUnsignedAndThePingPayloadVerbatim() throws {
        for (text, token) in [
            ("4270471497", UInt32(4_270_471_497)),
            ("0", 0),
            ("2147483647", 2_147_483_647),
            ("4294967295", 4_294_967_295)
        ] {
            let response = try XCTUnwrap(MoonlightRtspResponse.parse("RTSP/1.0 200 OK\r\nX-SS-Connect-Data: \(text)\r\n\r\n"))
            XCTAssertEqual(response.connectData(), token, text)
        }
        XCTAssertNil(try XCTUnwrap(MoonlightRtspResponse.parse("RTSP/1.0 200 OK\r\nX-SS-Connect-Data: -1\r\n\r\n")).connectData())
        XCTAssertNil(try XCTUnwrap(MoonlightRtspResponse.parse("RTSP/1.0 200 OK\r\n\r\n")).connectData())
        let media = try XCTUnwrap(MoonlightRtspResponse
            .parse("RTSP/1.0 200 OK\r\nX-SS-Ping-Payload: 9A615601970AEC19\r\nTransport: server_port=47998\r\n\r\n"))
        XCTAssertEqual(media.pingPayload(), "9A615601970AEC19")
        XCTAssertEqual(media.serverPort(), 47998)
        XCTAssertNil(try XCTUnwrap(MoonlightRtspResponse.parse("RTSP/1.0 200 OK\r\nTransport: unicast\r\n\r\n")).serverPort())
    }

    func testAnythingButAStatusLineIsRejected() {
        XCTAssertNil(MoonlightRtspResponse.parse(""))
        XCTAssertNil(MoonlightRtspResponse.parse("HTTP/1.1 200 OK\r\n\r\n"))
        XCTAssertNil(MoonlightRtspResponse.parse("RTSP/1.0 abc\r\n\r\n"))
        XCTAssertEqual(MoonlightRtspResponse.parse("RTSP/1.0 404 Not Found\r\n\r\n")?.ok, false)
        XCTAssertEqual(MoonlightRtspResponse.parse("RTSP/1.0 200\r\n\r\n")?.statusMessage, "")
    }
}
