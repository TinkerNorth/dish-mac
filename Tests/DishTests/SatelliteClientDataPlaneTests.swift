// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import DishCore
import XCTest
@testable import Dish

/// Session-state behavior of the protocol-1 data-plane client, driven
/// deterministically through `processIncoming` + a loopback capture socket:
/// the enriched-ack snapshot (gap G9 parse side), close-notify (G10 parse
/// side), the heartbeat-RTT latency window (G13), the send-counter exposure
/// for the proactive re-key poll (G4), and the full per-session state reset a
/// re-key performs (G1/G2). The live timer/receive-loop flows ride the
/// FakeSatellite-driven manager tests instead.
final class SatelliteClientDataPlaneTests: XCTestCase {

    private func ackDatagram(
        counter: UInt32,
        backend: Bool = true,
        count: UInt8 = 1,
        epoch: UInt16 = 3,
        bitmap: UInt16 = 0b1
    ) -> Data {
        var payload = Data([backend ? 1 : 0, count])
        payload.append(contentsOf: [UInt8(epoch >> 8), UInt8(epoch & 0xFF)])
        payload.append(contentsOf: [UInt8(bitmap >> 8), UInt8(bitmap & 0xFF)])
        return DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgHeartbeatAck,
            payload: payload,
            counter: counter
        )
    }

    // MARK: - Enriched heartbeat ack (gap G9 parse side)

    func testAckSnapshotNilBeforeFirstAck() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        XCTAssertNil(client.heartbeatAckSnapshot())
    }

    func testAckSnapshotReflectsParsedEnrichedFields() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        client.processIncoming(ackDatagram(counter: 1, backend: false, count: 2, epoch: 77, bitmap: 0b101))
        let snapshot = try XCTUnwrap(client.heartbeatAckSnapshot())
        XCTAssertFalse(snapshot.backendAvailable)
        XCTAssertEqual(snapshot.activeCount, 2)
        XCTAssertEqual(snapshot.epoch, 77)
        XCTAssertEqual(snapshot.bitmap, 0b101)
    }

    func testAckResetsMissCounterAndRevivesLiveness() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        client.missedAcks.set(4)
        client.connectionAlive.set(false)
        client.processIncoming(ackDatagram(counter: 1))
        XCTAssertEqual(client.missedAcks.get(), 0)
        XCTAssertTrue(client.connectionAlive.get())
    }

    func testShortAckCountsForLivenessButNotReconcile() throws {
        // A bare (pre-protocol-1) ack still proves the path; the reconcile
        // snapshot stays empty rather than guessing epoch/bitmap.
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        client.missedAcks.set(3)
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgHeartbeatAck,
            payload: Data([1, 0]),
            counter: 1
        ))
        XCTAssertEqual(client.missedAcks.get(), 0)
        XCTAssertTrue(client.connectionAlive.get())
        XCTAssertNil(client.heartbeatAckSnapshot())
    }

    // MARK: - Close notify (gap G10 parse side)

    func testCloseNotifyLatchesReasonMarksDeadAndFiresCallback() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        var received: [CloseReason] = []
        let lock = NSLock()
        client.onSessionClose = { reason in
            lock.lock()
            received.append(reason)
            lock.unlock()
        }

        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgSessionClose,
            payload: Data([CloseReason.kicked.rawValue]),
            counter: 1
        ))

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(received, [.kicked])
        XCTAssertEqual(client.sessionCloseReason.get(), Int(CloseReason.kicked.rawValue))
        XCTAssertFalse(client.connectionAlive.get(), "close marks dead NOW — no death-window wait")
    }

    func testCloseNotifyUnpairedReasonRoundTrips() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        var received: CloseReason?
        client.onSessionClose = { received = $0 }
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgSessionClose,
            payload: Data([CloseReason.unpaired.rawValue]),
            counter: 1
        ))
        XCTAssertEqual(received, .unpaired)
        XCTAssertEqual(closeActionForReason(.unpaired), .dropKeyAndStale, "W3-A policy input stays intact")
    }

    func testUnknownFutureCloseReasonDegradesToShutdown() throws {
        // Like the C++ ports' default arm: an unknown byte is a transient
        // close (backoff-retry), surfaced as .shutdown.
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        var received: CloseReason?
        client.onSessionClose = { received = $0 }
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgSessionClose,
            payload: Data([0x7F]),
            counter: 1
        ))
        XCTAssertEqual(received, .shutdown)
        XCTAssertEqual(client.sessionCloseReason.get(), 0x7F, "the latch keeps the RAW byte")
        XCTAssertFalse(client.connectionAlive.get())
    }

    func testEmptyClosePayloadIsDropped() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        var fired = false
        client.onSessionClose = { _ in fired = true }
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgSessionClose,
            payload: Data(),
            counter: 1
        ))
        XCTAssertFalse(fired)
        XCTAssertEqual(client.sessionCloseReason.get(), -1)
        XCTAssertTrue(client.connectionAlive.get())
    }

    // MARK: - Latency window (gap G13)

    func testLatencySnapshotSeedsFromPairedAck() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        XCTAssertNil(client.latencySnapshot().p50OneWayMs)
        XCTAssertEqual(client.latencySnapshot().samples, 0)

        client.armLatencyPing(nowMs: SatelliteClient.monotonicNowMs())
        client.processIncoming(ackDatagram(counter: 1))

        let snapshot = client.latencySnapshot()
        XCTAssertEqual(snapshot.samples, 1)
        let p50 = try XCTUnwrap(snapshot.p50OneWayMs)
        XCTAssertGreaterThanOrEqual(p50, 0)
        XCTAssertLessThan(p50, 2500, "a loopback-instant RTT must sit far under the 5 s loss cap")
    }

    func testDuplicateAckDoesNotDoubleCountTheInFlightPing() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        client.armLatencyPing(nowMs: SatelliteClient.monotonicNowMs())
        client.processIncoming(ackDatagram(counter: 1))
        client.processIncoming(ackDatagram(counter: 2))
        XCTAssertEqual(client.latencySnapshot().samples, 1, "the ping clock is consumed once")
    }

    // MARK: - Send counter exposure + re-key reset (gaps G4, G1/G2)

    func testSendCounterTracksUplinkSends() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }
        XCTAssertEqual(client.sendCounter, 0)
        client.sendReport(controllerIndex: 0, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0)
        client.sendBattery(controllerIndex: 0, level: 50, status: .charging)
        XCTAssertEqual(client.sendCounter, 2)
        XCTAssertFalse(counterNeedsRepush(client.sendCounter))
        client.params.mutate { $0.counter = UInt64(ProtocolConstants.counterRepushThreshold) }
        XCTAssertTrue(counterNeedsRepush(client.sendCounter), "the G4 poll sees the exposed counter")
    }

    func testRekeyRestartsCountersReplayGuardAndSnapshots() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }

        // Session 1 traffic: uplink counter advances, downlink guard latches,
        // snapshot + close latch populate.
        client.sendReport(controllerIndex: 0, buttons: 1, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0)
        _ = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
        client.processIncoming(ackDatagram(counter: 9))
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgSessionClose,
            payload: Data([CloseReason.replaced.rawValue]),
            counter: 10
        ))
        XCTAssertNotNil(client.heartbeatAckSnapshot())
        XCTAssertEqual(client.sessionCloseReason.get(), Int(CloseReason.replaced.rawValue))

        // Re-key on the SAME endpoint (the G4 path): fresh token + key.
        let key2 = SymmetricKey(data: Data(repeating: 0x77, count: 32))
        let token2: UInt32 = 0x0007_A1B3
        XCTAssertTrue(client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: port,
            token: token2,
            sessionKey: key2
        ))

        // Every per-session mirror restarted.
        XCTAssertEqual(client.sendCounter, 0)
        XCTAssertNil(client.heartbeatAckSnapshot())
        XCTAssertEqual(client.sessionCloseReason.get(), -1)
        XCTAssertTrue(client.connectionAlive.get())
        XCTAssertEqual(client.latencySnapshot().samples, 0)

        // Uplink seals with the NEW material and counters restart at 1.
        client.sendReport(controllerIndex: 0, buttons: 2, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0)
        let datagram = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
        let (counter, inner) = try XCTUnwrap(
            DataPlaneTestHelpers.openUplink(datagram, key: key2, token: token2)
        )
        XCTAssertEqual(counter, 1, "counters restart at 1 — no keystream reuse across sessions")
        XCTAssertEqual(inner.msgType, ProtocolConstants.msgInput)

        // Replay guard reset: a downlink at counter 1 (old guard was 10) is
        // accepted again under the new key.
        var fired = false
        client.onRumble = { _ in fired = true }
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1, 0, 1, 0, 1]),
            counter: 1,
            key: key2,
            token: token2
        ))
        XCTAssertTrue(fired, "the fresh session's guard starts at 0")

        // And the OLD session's material is dead: same datagram sealed with
        // session-1 params is dropped (token filter).
        fired = false
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1, 0, 1, 0, 1]),
            counter: 2
        ))
        XCTAssertFalse(fired, "old-token datagrams no longer decrypt after the re-key")
    }

    func testRekeySwapNeverYieldsAReusedCounterOrACarriedOneAcrossGenerations() throws {
        // `nextSendMaterial` is what every uplink seal draws from. Under
        // concurrent re-key swaps the drawn (token, sequence) pairs must
        // uphold the nonce invariant: no pair repeats within a generation,
        // and every generation's sequences run contiguously from 1 — a swap
        // can neither reset the counter under the old key (nonce reuse) nor
        // leak the old generation's high counter into the new one.
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }

        let drawsPerThread = 4000
        let threads = 4
        let collected = LockedBox<[(UInt32, UInt64)]>([])
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for _ in 0 ..< threads {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                var local: [(UInt32, UInt64)] = []
                local.reserveCapacity(drawsPerThread)
                for _ in 0 ..< drawsPerThread {
                    let material = client.nextSendMaterial()
                    local.append((material.token, material.sequence))
                }
                collected.mutate { $0.append(contentsOf: local) }
                group.leave()
            }
        }
        for _ in 0 ..< threads {
            start.signal()
        }
        // Re-key on the SAME endpoint (the live G4 path) while the senders
        // draw.
        for generation in 1 ... 200 {
            XCTAssertTrue(client.setConnectionParams(
                host: "127.0.0.1",
                udpPort: 9,
                token: UInt32(generation),
                sessionKey: SymmetricKey(data: Data(repeating: UInt8(generation % 251), count: 32))
            ))
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        var byGeneration: [UInt32: [UInt64]] = [:]
        for (token, sequence) in collected.get() {
            byGeneration[token, default: []].append(sequence)
        }
        for (token, sequences) in byGeneration {
            let unique = Set(sequences)
            XCTAssertEqual(
                unique.count,
                sequences.count,
                "token \(token): a (generation, counter) pair was drawn twice — nonce reuse"
            )
            XCTAssertEqual(
                unique,
                Set(1 ... UInt64(sequences.count)),
                "token \(token): sequences must run contiguously from 1"
            )
        }
    }

    func testExhaustedCounterGoesSilentInsteadOfWrapping() throws {
        // Contract §Crypto: a counter can never wrap — nonce reuse under one
        // key would be catastrophic. Past 2^32 − 1 the client stops sending
        // (the session self-heals via re-PUT; G4 re-keys long before).
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }

        client.params.mutate { $0.counter = UInt64(UInt32.max) - 1 }
        client.sendBattery(controllerIndex: 0, level: 1, status: .unknown)
        let last = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
        XCTAssertEqual(
            DataPlaneTestHelpers.openUplink(last)?.counter,
            UInt32.max,
            "the final counter value is still usable"
        )

        client.sendBattery(controllerIndex: 0, level: 2, status: .unknown)
        client.sendBattery(controllerIndex: 0, level: 3, status: .unknown)
        XCTAssertNil(
            DataPlaneTestHelpers.receiveDatagram(fd: fd),
            "past exhaustion the session goes silent — no wrapped nonces on the wire"
        )
        XCTAssertEqual(client.sendCounter, UInt32.max, "the G4 poll keeps reading re-PUT needed")
        XCTAssertTrue(counterNeedsRepush(client.sendCounter))
    }

    func testEndpointSwapJoinsTheReceiveLoopBeforeClosingItsSocket() throws {
        // The class invariant ("receive loop joined before the fd closes")
        // must hold on the live endpoint-swap replace path too, not just
        // `closeSocket` — otherwise a blocked recv can land on a reused fd.
        let (fdA, portA) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fdA) }
        let (fdB, portB) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fdB) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: portA))
        defer { client.closeSocket() }
        client.startReceiveLoop()
        XCTAssertTrue(client.ackRunning.get())

        XCTAssertTrue(client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: portB,
            token: DataPlaneTestHelpers.testToken,
            sessionKey: DataPlaneTestHelpers.testKey
        ))

        XCTAssertFalse(
            client.ackRunning.get(),
            "an endpoint swap must stop the receive loop before the old fd closes"
        )
        XCTAssertEqual(
            client.receiveDrained.wait(timeout: .now()),
            .success,
            "the old receive loop must have exited (joined), not been left on a closed fd"
        )
        XCTAssertTrue(client.isOpen)
        client.sendBattery(controllerIndex: 0, level: 9, status: .unknown)
        XCTAssertNotNil(
            DataPlaneTestHelpers.receiveDatagram(fd: fdB),
            "the client must be aimed at the NEW endpoint after the swap"
        )
    }

    func testClosedClientDropsSendsWithoutTrapping() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        client.closeSocket()
        client.sendReport(controllerIndex: 0, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0)
        XCTAssertEqual(client.sendCounter, 0, "sends on a closed client are dropped before sealing")
    }
}
