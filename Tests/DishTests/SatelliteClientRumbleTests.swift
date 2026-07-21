// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import Dish

/// The protocol-1 rumble return path through the REAL receive pipeline —
/// `SatelliteClient.processIncoming` is driven directly with datagrams sealed
/// exactly like the satellite's (`DishCore.SessionCrypto`, direction `down`,
/// AAD = token), so header parsing, the replay guard (gap G3), AEAD binding
/// (gaps G1/G2) and dispatch are all exercised without socket timing. The
/// payload *field* decoding is pinned separately in
/// `Tests/DishCoreTests/EncodersTests.swift` (`RumbleCommand.parse`).
final class SatelliteClientRumbleTests: XCTestCase {

    private var client: SatelliteClient!
    private var received: [RumbleCommand] = []
    private let receivedLock = NSLock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        client = try XCTUnwrap(DataPlaneTestHelpers.makeClient())
        received = []
        client.onRumble = { [weak self] command in
            guard let self else { return }
            self.receivedLock.lock()
            self.received.append(command)
            self.receivedLock.unlock()
        }
    }

    override func tearDown() {
        client?.closeSocket()
        client = nil
        super.tearDown()
    }

    private var receivedSnapshot: [RumbleCommand] {
        receivedLock.lock()
        defer { receivedLock.unlock() }
        return received
    }

    private func rumbleDatagram(
        counter: UInt32,
        ctrlIdx: UInt8 = 0,
        strong: UInt16 = 0xABCD,
        weak: UInt16 = 0x1234,
        durationMs: UInt16 = 500
    ) -> Data {
        var payload = Data([ctrlIdx])
        payload.append(contentsOf: [UInt8(strong >> 8), UInt8(strong & 0xFF)])
        payload.append(contentsOf: [UInt8(weak >> 8), UInt8(weak & 0xFF)])
        payload.append(contentsOf: [UInt8(durationMs >> 8), UInt8(durationMs & 0xFF)])
        return DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: payload,
            counter: counter
        )
    }

    // MARK: - Decode through the real pipeline

    func testRumbleDatagramDispatchesDecodedCommand() {
        client.processIncoming(rumbleDatagram(counter: 1, ctrlIdx: 3))
        let got = receivedSnapshot
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.controllerIndex, 3)
        XCTAssertEqual(got.first?.strongMagnitude, 0xABCD)
        XCTAssertEqual(got.first?.weakMagnitude, 0x1234)
        XCTAssertEqual(got.first?.durationMs, 500)
    }

    func testStopRequestZeroMagnitudesDispatch() {
        client.processIncoming(rumbleDatagram(counter: 1, strong: 0, weak: 0, durationMs: 0))
        XCTAssertEqual(receivedSnapshot.first?.strongMagnitude, 0)
        XCTAssertEqual(receivedSnapshot.first?.weakMagnitude, 0)
    }

    // MARK: - Replay guard (gap G3)

    func testReplayedDatagramIsDroppedOnce() {
        let datagram = rumbleDatagram(counter: 5)
        client.processIncoming(datagram)
        client.processIncoming(datagram) // exact replay: counter <= last
        XCTAssertEqual(receivedSnapshot.count, 1, "replayed counter must be dropped")
    }

    func testRegressedCounterIsDropped() {
        client.processIncoming(rumbleDatagram(counter: 8))
        client.processIncoming(rumbleDatagram(counter: 7))
        XCTAssertEqual(receivedSnapshot.count, 1, "counter <= last must be dropped")
        client.processIncoming(rumbleDatagram(counter: 9))
        XCTAssertEqual(receivedSnapshot.count, 2, "the stream continues past a dropped replay")
    }

    func testFirstPacketExemptionAcceptsAnyStartingCounter() {
        // The satellite's down counter may be far along by the time we join
        // (first packet exempt while the guard is 0).
        client.processIncoming(rumbleDatagram(counter: 41))
        XCTAssertEqual(receivedSnapshot.count, 1)
    }

    func testForgedHeaderCounterDoesNotAdvanceTheGuard() {
        // An attacker replays a datagram with a REWRITTEN (huge) header
        // counter: the AEAD open fails (counter is nonce-bound), and the
        // guard must not advance — the genuine stream keeps flowing.
        var forged = rumbleDatagram(counter: 1)
        forged.replaceSubrange(4 ..< 8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        client.processIncoming(forged)
        client.processIncoming(rumbleDatagram(counter: 1))
        XCTAssertEqual(receivedSnapshot.count, 1, "genuine counter 1 must still be accepted")
    }

    // MARK: - AEAD binding (gaps G1/G2)

    func testWrongTokenIsDropped() {
        let alien = DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1, 0, 1, 0, 1]),
            counter: 1,
            token: 0xDEAD_BEEF
        )
        client.processIncoming(alien)
        XCTAssertTrue(receivedSnapshot.isEmpty)
    }

    func testUplinkDirectionSealIsRejectedDownstream() {
        // Same key/token/counter but sealed with the CLIENT direction byte:
        // the two directions must never share a nonce, so the downstream
        // open rejects it.
        let inner = PacketCodec.innerFrame(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1, 0, 1, 0, 1])
        )
        guard let box = try? SessionCrypto.seal(
            inner,
            key: DataPlaneTestHelpers.testKey,
            direction: .up,
            counter: 1,
            token: DataPlaneTestHelpers.testToken
        ) else { return XCTFail("seal failed") }
        client.processIncoming(
            PacketCodec.frame(token: DataPlaneTestHelpers.testToken, counter: 1, box: box)
        )
        XCTAssertTrue(receivedSnapshot.isEmpty)
    }

    func testTamperedCiphertextIsDropped() {
        var datagram = rumbleDatagram(counter: 1)
        let index = datagram.count - 1
        datagram[index] ^= 0x01
        client.processIncoming(datagram)
        XCTAssertTrue(receivedSnapshot.isEmpty)
    }

    func testTruncatedRumblePayloadIsDropped() {
        let short = DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0, 1]),
            counter: 1
        )
        client.processIncoming(short)
        XCTAssertTrue(receivedSnapshot.isEmpty, "truncated payload must not dispatch")
    }
}
