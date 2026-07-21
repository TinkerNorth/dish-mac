// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import Dish

/// Protocol-1 touchpad uplink + lightbar downlink through the REAL client:
///
///   * `sendTouchpad` — the datagram captured off a loopback socket must
///     open with the satellite's parameters (direction `up`, AAD = token)
///     and carry the 16-byte §0x000C payload incl. the trailing
///     `eventTimeMs` u32 LE at offset 12 (gap G12; the server drops legacy
///     12-byte bodies).
///   * MSG_LIGHTBAR — `processIncoming` dispatch to `onLightbar` with the
///     decoded colour.
///
/// The pure byte-layout permutations (flags bits, LE boundaries) are pinned
/// in `Tests/DishCoreTests/EncodersTests.swift`; these tests prove the CLIENT
/// path uses those encoders end-to-end.
final class TouchpadLightbarTests: XCTestCase {

    // MARK: - Touchpad uplink (gap G12)

    func testTouchpadUplinkCarriesSixteenByteFrameWithEventTime() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }

        client.sendTouchpad(
            controllerIndex: 2,
            finger0Active: true,
            finger0Id: 0x11,
            finger0X: 0x0102,
            finger0Y: -2,
            finger1Active: false,
            finger1Id: 0x22,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: true,
            eventTimeMs: 0xA1B2_C3D4
        )

        let datagram = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
        let (counter, inner) = try XCTUnwrap(DataPlaneTestHelpers.openUplink(datagram))
        XCTAssertEqual(counter, 1, "per-direction counters start at 1")
        XCTAssertEqual(inner.msgType, ProtocolConstants.msgTouchpad)
        XCTAssertEqual(inner.declaredLength, 16)
        let payload = [UInt8](inner.payload)
        XCTAssertEqual(payload.count, 16, "protocol-1 touchpad payload is 16 bytes")
        XCTAssertEqual(payload[0], 2)
        XCTAssertEqual(payload[1], 0x05, "finger0 active (b0) + button (b2)")
        XCTAssertEqual(payload[2], 0x11)
        XCTAssertEqual(Array(payload[3 ... 4]), [0x02, 0x01], "finger0X LE")
        XCTAssertEqual(Array(payload[5 ... 6]), [0xFE, 0xFF], "finger0Y −2 LE two's complement")
        XCTAssertEqual(payload[7], 0x22)
        XCTAssertEqual(
            Array(payload[12 ... 15]),
            [0xD4, 0xC3, 0xB2, 0xA1],
            "eventTimeMs u32 LE at offset 12 — the protocol-1 addition"
        )
    }

    func testEveryUplinkStreamSharesTheCounterSequence() throws {
        // Counter discipline across message types: input → battery → touchpad
        // ride one monotonically increasing per-direction sequence.
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }

        client.sendReport(controllerIndex: 0, buttons: 1, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0)
        client.sendBattery(controllerIndex: 0, level: 80, status: .discharging)
        client.sendTouchpad(
            controllerIndex: 0,
            finger0Active: false,
            finger0Id: 0,
            finger0X: 0,
            finger0Y: 0,
            finger1Active: false,
            finger1Id: 0,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: false,
            eventTimeMs: 7
        )

        var seen: [UInt16: UInt32] = [:]
        for _ in 0 ..< 3 {
            let datagram = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd))
            let (counter, inner) = try XCTUnwrap(DataPlaneTestHelpers.openUplink(datagram))
            seen[inner.msgType] = counter
        }
        XCTAssertEqual(seen[ProtocolConstants.msgInput], 1)
        XCTAssertEqual(seen[ProtocolConstants.msgBattery], 2)
        XCTAssertEqual(seen[ProtocolConstants.msgTouchpad], 3)
    }

    // MARK: - Lightbar downlink

    func testLightbarDatagramDispatchesDecodedColour() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        var received: [LightbarCommand] = []
        let lock = NSLock()
        client.onLightbar = { command in
            lock.lock()
            received.append(command)
            lock.unlock()
        }

        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgLightbar,
            payload: Data([3, 0xDE, 0xAD, 0xBE]),
            counter: 1
        ))

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.controllerIndex, 3)
        XCTAssertEqual(received.first?.r, 0xDE)
        XCTAssertEqual(received.first?.g, 0xAD)
        XCTAssertEqual(received.first?.b, 0xBE)
    }

    func testTruncatedLightbarPayloadIsDropped() throws {
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        defer { client.closeSocket() }
        var fired = false
        client.onLightbar = { _ in fired = true }

        client.processIncoming(DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgLightbar,
            payload: Data([1, 2, 3]),
            counter: 1
        ))
        XCTAssertFalse(fired)
    }
}
