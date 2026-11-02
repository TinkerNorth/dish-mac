// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import DishCore
import XCTest
@testable import DishEngine

/// The receive loop's state without locks: the handlers the main actor sets
/// reach the running loop, the ack the loop stores reaches the alive tick
/// whole, and the ack time the loop leaves reaches the latency window.
final class SatelliteClientReceiveTests: XCTestCase {

    func testAHandlerSetWhileTheLoopRunsIsTheOneTheLoopCalls() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }
        client.startReceiveLoop()
        client.sendReport(controllerIndex: 0, report: GamepadReport())
        let clientAddress = try XCTUnwrap(receiveSender(fd: fd), "the client's first send names its port")

        let arrived = expectation(description: "the handler set after the loop started")
        let heard = LockedBox<[RumbleCommand]>([])
        client.onRumble = { command in
            heard.mutate { $0.append(command) }
            arrived.fulfill()
        }
        let rumble = DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0x75, 0x30, 0x27, 0x10, 0x01, 0xF4]),
            counter: 1
        )
        XCTAssertTrue(send(rumble, from: fd, to: clientAddress))
        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(heard.get(), [RumbleCommand(controllerIndex: 0, strongMagnitude: 30000, weakMagnitude: 10000, durationMs: 500)])
    }

    func testAPackedAckReadsBackWholeAndTheEmptyWordReadsNone() {
        let acks = [
            HeartbeatAck(backendAvailable: true, activeCount: 4, epoch: 0xFFFF, bitmap: 0xFFFF),
            HeartbeatAck(backendAvailable: false, activeCount: 0, epoch: 0, bitmap: 0),
            HeartbeatAck(backendAvailable: true, activeCount: 255, epoch: 0x0102, bitmap: 0x8001)
        ]
        for ack in acks {
            XCTAssertEqual(HeartbeatAck(packed: ack.packed), ack)
        }
        XCTAssertNil(HeartbeatAck(packed: 0))
    }

    func testAnAckStoredOnOneThreadIsReadWholeOnAnother() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        let ack = HeartbeatAck(backendAvailable: true, activeCount: 2, epoch: 7, bitmap: 3)
        let stored = DispatchSemaphore(value: 0)
        Thread {
            client.storeHeartbeatAck(ack)
            stored.signal()
        }.start()
        XCTAssertEqual(stored.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(client.heartbeatAckSnapshot(), ack)
    }

    func testAnAckTimeLeftOnTheReceiveThreadIsPairedByTheNextReader() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        let sentMs = SatelliteClient.monotonicNowMs()
        client.armLatencyPing(nowMs: sentMs)
        let recorded = DispatchSemaphore(value: 0)
        Thread {
            client.recordLatencyAck(nowMs: sentMs + 8)
            recorded.signal()
        }.start()
        XCTAssertEqual(recorded.wait(timeout: .now() + 5), .success)
        let snapshot = client.latencySnapshot()
        XCTAssertEqual(snapshot.samples, 1)
        XCTAssertEqual(snapshot.p50OneWayMs, 4, "an 8 ms round trip halves to 4 ms one way")
    }

    func testARekeyForgetsAnAckTimeNotYetPaired() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        let sentMs = SatelliteClient.monotonicNowMs()
        client.armLatencyPing(nowMs: sentMs)
        client.recordLatencyAck(nowMs: sentMs + 8)
        XCTAssertTrue(client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: 9,
            token: DataPlaneTestHelpers.testToken &+ 1,
            sessionKey: DataPlaneTestHelpers.testKey
        ))
        XCTAssertEqual(client.latencySnapshot().samples, 0)
    }

    /// The client's address as its datagram names it.
    private func receiveSender(fd: Int32) -> sockaddr_in? {
        var buffer = [UInt8](repeating: 0, count: ProtocolConstants.udpDatagramMaxBytes)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) }
            }
        }
        return count > 0 ? from : nil
    }

    private func send(_ datagram: Data, from fd: Int32, to address: sockaddr_in) -> Bool {
        var destination = address
        let written = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return written == datagram.count
    }
}
