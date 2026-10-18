// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The UDP edges against loopback listeners: the control socket round trip,
/// and the media pings in both forms on the lanes the host named.
final class MoonlightUdpTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testTheControlSocketSendsAndHearsBack() async throws {
        let echo = MoonlightLoopbackUdp(echo: true)
        let port = try echo.start()
        defer { echo.stop() }
        let transport = UdpControlTransport(address: "127.0.0.1", port: port)
        let heard = LockedBox<[Data]>([])
        transport.onDatagram = { datagram in heard.mutate { $0.append(datagram) } }
        let ready = await transport.start()
        XCTAssertTrue(ready)
        transport.send(Data([0x8F, 0xFF, 0x12, 0x34]))
        let answered = await waitUntil { heard.get() == [Data([0x8F, 0xFF, 0x12, 0x34])] }
        XCTAssertTrue(answered, "the echo came back on the transport's queue")
        XCTAssertEqual(echo.datagrams(), [Data([0x8F, 0xFF, 0x12, 0x34])])
        transport.close()
    }

    func testThePingerSendsThePayloadFormOnBothLanesEveryHalfSecond() async throws {
        let video = MoonlightLoopbackUdp()
        let audio = MoonlightLoopbackUdp()
        let videoPort = try video.start()
        let audioPort = try audio.start()
        defer {
            video.stop()
            audio.stop()
        }
        let pinger = MoonlightMediaPinger(address: "127.0.0.1", videoPort: videoPort, audioPort: audioPort, payload: "68A75BBEEEA86826")
        XCTAssertEqual(pinger.mode, "SS_PING")
        pinger.start()
        let twoEach = await waitUntil { video.count() >= 2 && audio.count() >= 2 }
        pinger.stop()
        XCTAssertTrue(twoEach, "the first at once, the second half a second later")
        XCTAssertEqual(video.datagrams().first, MoonlightMediaPing.ssPing(payload: "68A75BBEEEA86826", sequence: 0))
        XCTAssertEqual(video.datagrams().dropFirst().first, MoonlightMediaPing.ssPing(payload: "68A75BBEEEA86826", sequence: 1))
        XCTAssertEqual(audio.datagrams().first?.count, 20)
        XCTAssertGreaterThanOrEqual(pinger.pingsSent, 2)
    }

    func testThePingerFallsBackToTheLegacyWordAndSkipsALaneTheHostDidNotName() async throws {
        let video = MoonlightLoopbackUdp()
        let videoPort = try video.start()
        defer { video.stop() }
        let pinger = MoonlightMediaPinger(address: "127.0.0.1", videoPort: videoPort, audioPort: nil, payload: "")
        XCTAssertEqual(pinger.mode, "legacy PING")
        pinger.start()
        let one = await waitUntil { video.count() >= 1 }
        pinger.stop()
        XCTAssertTrue(one)
        XCTAssertEqual(video.datagrams().first, Data("PING".utf8))
    }
}
