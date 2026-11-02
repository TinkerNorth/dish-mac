// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import DishCore
import XCTest
@testable import DishEngine

/// Every sender holds the send gate from its counter's claim to its
/// `sendto`: datagrams leave in counter order whoever sends them, a re-key
/// never pairs one generation's key with the other's counter, and a send the
/// socket refuses is dropped without holding up the next.
final class SatelliteClientSendGateTests: XCTestCase {

    private static let senders = 4
    private static let sendsEach = 500

    func testConcurrentSendersLeaveInCounterOrder() throws {
        let (fd, port) = try bigLoopbackSocket()
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }
        sendConcurrently(client)

        let counters = drain(fd).compactMap { DataPlaneTestHelpers.openUplink($0)?.counter }
        XCTAssertGreaterThan(counters.count, Self.senders * Self.sendsEach / 2, "the loopback kept most of the burst")
        XCTAssertEqual(counters, counters.sorted(), "datagrams left in counter order")
        XCTAssertEqual(Set(counters).count, counters.count, "no counter was used twice")
        XCTAssertEqual(client.sendCounter, UInt32(Self.senders * Self.sendsEach))
    }

    func testARekeyUnderConcurrentSendsNeverMixesGenerations() throws {
        let (fd, port) = try bigLoopbackSocket()
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }
        var keys = [DataPlaneTestHelpers.testToken: DataPlaneTestHelpers.testKey]
        for generation in 1 ... 20 {
            keys[UInt32(generation)] = SymmetricKey(data: Data(repeating: UInt8(generation), count: 32))
        }
        let rekeyed = DispatchSemaphore(value: 0)
        Thread { [keys] in
            for generation in 1 ... 20 {
                let token = UInt32(generation)
                _ = client.setConnectionParams(
                    host: "127.0.0.1",
                    udpPort: port,
                    token: token,
                    sessionKey: keys[token] ?? DataPlaneTestHelpers.testKey
                )
            }
            rekeyed.signal()
        }.start()
        sendConcurrently(client)
        XCTAssertEqual(rekeyed.wait(timeout: .now() + 30), .success)

        var lastCounter: [UInt32: UInt32] = [:]
        for datagram in drain(fd) {
            let header = try XCTUnwrap(PacketCodec.parse(datagram)?.header)
            let key = try XCTUnwrap(keys[header.token])
            let opened = DataPlaneTestHelpers.openUplink(datagram, key: key, token: header.token)
            XCTAssertEqual(opened?.counter, header.counter, "token \(header.token) opens only under its own key")
            XCTAssertGreaterThan(header.counter, lastCounter[header.token] ?? 0, "token \(header.token) counters only rise")
            lastCounter[header.token] = header.counter
        }
    }

    func testASendTheSocketRefusesIsDroppedAndTheNextOneGoes() {
        let attempts = LockedBox(0)
        let client = SatelliteClient { _, _, _, _, _, _ in
            attempts.mutate { $0 += 1 }
            errno = EAGAIN
            return -1
        }
        defer { client.closeSocket() }
        XCTAssertTrue(client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: 9,
            token: DataPlaneTestHelpers.testToken,
            sessionKey: DataPlaneTestHelpers.testKey
        ))
        client.sendReport(controllerIndex: 0, report: GamepadReport())
        XCTAssertFalse(client.gate.isTaken, "a refused send gives the gate back")
        client.sendReport(controllerIndex: 0, report: GamepadReport())
        XCTAssertEqual(attempts.get(), 2, "each send tried once and was not retried")
        XCTAssertEqual(client.sendCounter, 2, "a dropped datagram still spent its counter")
    }

    func testTheGateAdmitsOneHolderAtATime() {
        let gate = SendGate()
        let tally = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        tally.initialize(to: 0)
        defer { tally.deallocate() }
        let group = DispatchGroup()
        for _ in 0 ..< Self.senders {
            group.enter()
            Thread {
                for _ in 0 ..< 20000 {
                    gate.hold { tally.pointee += 1 }
                }
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(tally.pointee, Self.senders * 20000)
        XCTAssertFalse(gate.isTaken)
    }

    private func sendConcurrently(_ client: SatelliteClient) {
        let group = DispatchGroup()
        for sender in 0 ..< Self.senders {
            group.enter()
            Thread {
                for frame in 0 ..< Self.sendsEach {
                    client.sendReport(controllerIndex: sender, report: GamepadReport(rx: Int16(frame)))
                }
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
    }

    /// A loopback socket with room for the whole burst, so the kernel keeps
    /// what the senders send.
    private func bigLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        var bytes: Int32 = 8 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (fd, port)
    }

    /// Every datagram waiting, in arrival order.
    private func drain(_ fd: Int32) -> [Data] {
        var datagrams: [Data] = []
        while let datagram = DataPlaneTestHelpers.receiveDatagram(fd: fd) {
            datagrams.append(datagram)
        }
        return datagrams
    }
}
