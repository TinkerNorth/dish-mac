// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import DishCore
import XCTest
@testable import DishEngine

/// The proactive re-key on the same socket: every per-session mirror
/// restarts, the uplink seals with the new material from counter 1, the old
/// material is dead, and concurrent draws never reuse a nonce.
final class SatelliteClientRekeyTests: XCTestCase {

    private let secondKey = SymmetricKey(data: Data(repeating: 0x77, count: 32))
    private let secondToken: UInt32 = 0x0007_A1B3

    /// A client that has already streamed one session: the uplink counter
    /// advanced, the downlink guard latched, the ack snapshot and the close
    /// latch are populated.
    private func clientAfterOneSession(fd: Int32, port: UInt16) throws -> SatelliteClient {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        client.sendReport(controllerIndex: 0, report: GamepadReport(buttons: 1))
        _ = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
        client.processIncoming(DataPlaneTestHelpers.ackDatagram(counter: 9))
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgSessionClose,
            payload: Data([CloseReason.replaced.rawValue]),
            counter: 10
        ))
        XCTAssertNotNil(client.heartbeatAckSnapshot())
        XCTAssertEqual(client.sessionCloseReason.get(), Int(CloseReason.replaced.rawValue))
        return client
    }

    private func rekeyOnTheSameEndpoint(_ client: SatelliteClient, port: UInt16) {
        XCTAssertTrue(client.setConnectionParams(host: "127.0.0.1", udpPort: port, token: secondToken, sessionKey: secondKey))
    }

    func testRekeyRestartsEveryPerSessionMirror() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try clientAfterOneSession(fd: fd, port: port)
        defer { client.closeSocket() }

        rekeyOnTheSameEndpoint(client, port: port)

        XCTAssertEqual(client.sendCounter, 0)
        XCTAssertNil(client.heartbeatAckSnapshot())
        XCTAssertEqual(client.sessionCloseReason.get(), -1)
        XCTAssertTrue(client.connectionAlive.get())
        XCTAssertEqual(client.latencySnapshot().samples, 0)
    }

    func testAfterARekeyTheUplinkSealsWithTheNewMaterialFromCounterOne() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try clientAfterOneSession(fd: fd, port: port)
        defer { client.closeSocket() }
        rekeyOnTheSameEndpoint(client, port: port)

        client.sendReport(controllerIndex: 0, report: GamepadReport(buttons: 2))
        let datagram = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
        let (counter, inner) = try XCTUnwrap(DataPlaneTestHelpers.openUplink(datagram, key: secondKey, token: secondToken))
        XCTAssertEqual(counter, 1, "counters restart at 1, so no keystream is reused across sessions")
        XCTAssertEqual(inner.msgType, ProtocolConstants.msgInput)
    }

    func testAfterARekeyTheReplayGuardStartsOverAndTheOldMaterialIsDead() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try clientAfterOneSession(fd: fd, port: port)
        defer { client.closeSocket() }
        rekeyOnTheSameEndpoint(client, port: port)

        var fired = false
        client.onRumble = { _ in fired = true }
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1, 0, 1, 0, 1]),
            counter: 1,
            key: secondKey,
            token: secondToken
        ))
        XCTAssertTrue(fired, "the fresh session's guard starts at 0, so counter 1 is accepted")

        fired = false
        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1, 0, 1, 0, 1]),
            counter: 2
        ))
        XCTAssertFalse(fired, "a datagram under the old token no longer decrypts")
    }

    // MARK: - Concurrent draws

    private static let drawsPerThread = 4000
    private static let threads = 4
    private static let generations = 200

    /// Four threads draw send material as fast as they can.
    private func drawConcurrently(_ client: SatelliteClient) -> (DispatchGroup, LockedBox<[(UInt32, UInt64)]>) {
        let collected = LockedBox<[(UInt32, UInt64)]>([])
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for _ in 0 ..< Self.threads {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                var local: [(UInt32, UInt64)] = []
                local.reserveCapacity(Self.drawsPerThread)
                for _ in 0 ..< Self.drawsPerThread {
                    let material = client.nextSendMaterial()
                    local.append((material.token, material.sequence))
                }
                collected.mutate { $0.append(contentsOf: local) }
                group.leave()
            }
        }
        for _ in 0 ..< Self.threads {
            start.signal()
        }
        return (group, collected)
    }

    /// Re-key on the same endpoint, once per generation, while the senders draw.
    private func rekeyRepeatedly(_ client: SatelliteClient) {
        for generation in 1 ... Self.generations {
            XCTAssertTrue(client.setConnectionParams(
                host: "127.0.0.1",
                udpPort: 9,
                token: UInt32(generation),
                sessionKey: SymmetricKey(data: Data(repeating: UInt8(generation % 251), count: 32))
            ))
        }
    }

    /// Within one generation no (token, counter) pair repeats and the
    /// sequences run contiguously from 1: a swap can neither reset the counter
    /// under the old key nor carry the old high counter into the new one.
    func testRekeySwapNeverYieldsAReusedCounterOrACarriedOneAcrossGenerations() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        let (group, collected) = drawConcurrently(client)
        rekeyRepeatedly(client)
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        var byGeneration: [UInt32: [UInt64]] = [:]
        for (token, sequence) in collected.get() {
            byGeneration[token, default: []].append(sequence)
        }
        for (token, sequences) in byGeneration {
            let unique = Set(sequences)
            XCTAssertEqual(unique.count, sequences.count, "token \(token): a (generation, counter) pair was drawn twice")
            XCTAssertEqual(unique, Set(1 ... UInt64(sequences.count)), "token \(token): sequences must run contiguously from 1")
        }
    }
}
