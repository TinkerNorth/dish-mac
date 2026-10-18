// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The ENet client against hand-built host datagrams and an injected clock:
/// the handshake, the ack bytes, in-order delivery with a held gap, every
/// command number measured, the retransmit and give-up clock, the ping,
/// and the round-trip estimate rounded as the fork rounds it.
final class EnetClientTests: XCTestCase {

    private var clock: Int64 = 0x4321
    private var client: EnetClient!

    override func setUp() {
        super.setUp()
        clock = 0x4321
        client = EnetClient(connectData: 0xFE88_1C39, now: { self.clock }, random: { 0x0102_0304 })
    }

    // MARK: - Host datagrams

    /// A datagram from the host addressed to us (peer 0) under session 2, with a sent time.
    private func hostDatagram(sentTime: UInt16? = 0x1234, session: UInt8 = 2, peer: UInt16 = 0, _ commands: [UInt8]...) -> Data {
        var writer = ByteWriter(capacity: 64)
        var word = peer | UInt16(session) << 12
        if sentTime != nil { word |= 0x8000 }
        writer.u16BE(word)
        if let sentTime { writer.u16BE(sentTime) }
        for command in commands {
            writer.append(Data(command))
        }
        return writer.data
    }

    private func verifyConnect(
        peerId: UInt16 = 0x42,
        connectId: UInt32 = 0x0102_0304,
        mtu: UInt32 = 1400,
        interval: UInt32 = 5000
    ) -> [UInt8] {
        var writer = ByteWriter(capacity: 44)
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandVerifyConnect | EnetProtocol.flagAcknowledge,
            channel: 0xFF,
            reliableSequence: 1
        )
        writer.u16BE(peerId)
        writer.u8(2)
        writer.u8(2)
        writer.u32BE(mtu)
        writer.u32BE(65536)
        writer.u32BE(1)
        writer.u32BE(0)
        writer.u32BE(0)
        writer.u32BE(interval)
        writer.u32BE(2)
        writer.u32BE(2)
        writer.u32BE(connectId)
        return [UInt8](writer.data)
    }

    private func sendReliable(seq: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var writer = ByteWriter(capacity: 6 + payload.count)
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandSendReliable | EnetProtocol.flagAcknowledge,
            channel: 0,
            reliableSequence: seq
        )
        writer.u16BE(UInt16(payload.count))
        writer.append(Data(payload))
        return [UInt8](writer.data)
    }

    private func ack(channel: UInt8, seq: UInt16, sentTime: UInt16) -> [UInt8] {
        var writer = ByteWriter(capacity: 8)
        EnetWire.commandHeader(&writer, command: EnetProtocol.commandAcknowledge, channel: channel, reliableSequence: seq)
        writer.u16BE(seq)
        writer.u16BE(sentTime)
        return [UInt8](writer.data)
    }

    private func ping(seq: UInt16) -> [UInt8] {
        var writer = ByteWriter(capacity: 4)
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandPing | EnetProtocol.flagAcknowledge,
            channel: 0xFF,
            reliableSequence: seq
        )
        return [UInt8](writer.data)
    }

    @discardableResult
    private func connectAndVerify() -> Data {
        let connect = client.connect()
        _ = client.onDatagram(hostDatagram(session: 0, peer: 0, verifyConnect()))
        return connect
    }

    // MARK: - The handshake

    func testConnectIsFortyEightBytesOnTheSystemChannelAddressedToNoPeerYet() {
        let datagram = connectAndVerify()
        XCTAssertEqual(datagram.count, 4 + 48)
        XCTAssertEqual(Array(datagram.prefix(4)), [0x8F, 0xFF, 0x43, 0x21], "sent-time flag | peer 0xFFF, then the clock's low word")
        XCTAssertEqual(Array(datagram[4 ..< 8]), [0x82, 0xFF, 0x00, 0x01], "CONNECT wanting an ack, system channel, seq 1")
        XCTAssertEqual(Array(datagram[8 ..< 12]), [0x00, 0x00, 0xFF, 0xFF], "peer 0, no session ids yet")
        XCTAssertEqual(Array(datagram[12 ..< 16]), [0x00, 0x00, 0x05, 0x78], "mtu 1400")
        XCTAssertEqual(Array(datagram[48 ..< 52]), [0xFE, 0x88, 0x1C, 0x39], "the SETUP's connect data, last")
        XCTAssertEqual(client.state, .connected)
    }

    func testVerifyConnectIsAcknowledgedAndTheHeaderThenNamesTheHostsIds() {
        _ = client.connect()
        let acks = client.onDatagram(hostDatagram(sentTime: 0x1111, session: 0, peer: 0, verifyConnect()))
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(Array(acks[0].prefix(2)), [0xA0, 0x42], "sent-time flag | session 2 | peer 0x42")
        XCTAssertEqual(Array(acks[0].dropFirst(4)), [0x01, 0xFF, 0x00, 0x01, 0x00, 0x01, 0x11, 0x11])
        XCTAssertNotNil(client.sendReliable(Data()), "a connected client sends")
    }

    func testVerifyConnectForAnotherConnectionIsRefused() {
        _ = client.connect()
        _ = client.onDatagram(hostDatagram(session: 0, verifyConnect(connectId: 0xDEAD_BEEF)))
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertEqual(client.disconnectReason, "VERIFY_CONNECT names another connection")
    }

    func testAnAckForAHostPingIsTheFixtureBytes() {
        connectAndVerify()
        let acks = client.onDatagram(hostDatagram(sentTime: 0x1234, ping(seq: 7)))
        XCTAssertEqual(acks.map(hexString), ["a042432101ff000700071234"])
        XCTAssertEqual(client.stats.acksSent, 2, "the verify and the ping")
    }

    func testACommandWithoutASentTimeIsNotAcknowledgedAndEndsTheWalk() {
        connectAndVerify()
        let acks = client.onDatagram(hostDatagram(sentTime: nil, ping(seq: 7), sendReliable(seq: 1, [0xAA])))
        XCTAssertEqual(acks, [])
        XCTAssertEqual(client.takeReceived(), [], "the command behind the unanswerable one was not reached")
    }

    // MARK: - Reliable delivery

    func testReliablePayloadsArriveInOrderAHeldGapFillsAndADuplicateIsAckedNotRedelivered() {
        connectAndVerify()
        _ = client.onDatagram(hostDatagram(sendReliable(seq: 1, [0x01])))
        _ = client.onDatagram(hostDatagram(sendReliable(seq: 3, [0x03])))
        XCTAssertEqual(client.takeReceived(), [Data([0x01])], "3 waits for 2")
        XCTAssertEqual(client.stats.heldOutOfOrder, 1)
        let acks = client.onDatagram(hostDatagram(sendReliable(seq: 2, [0x02])))
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(client.takeReceived(), [Data([0x02]), Data([0x03])], "the gap filled, both delivered in order")
        let again = client.onDatagram(hostDatagram(sendReliable(seq: 2, [0x02])))
        XCTAssertEqual(again.count, 1, "a retransmitted command is acknowledged again")
        XCTAssertEqual(client.takeReceived(), [], "but not delivered twice")
    }

    func testTheSixteenBitSequenceWraps() {
        connectAndVerify()
        for seq in UInt16(1) ... 3 {
            _ = client.onDatagram(hostDatagram(sendReliable(seq: seq, [UInt8(seq)])))
        }
        _ = client.takeReceived()
        // Jump the ring: nothing lands until the numbers close in.
        _ = client.onDatagram(hostDatagram(sendReliable(seq: 0x7FFF, [0xFF])))
        XCTAssertEqual(client.takeReceived(), [], "too far ahead: discarded")
    }

    func testEveryCommandNumberIsMeasuredSoTheAcksBehindItSurvive() {
        connectAndVerify()
        var bandwidth = ByteWriter(capacity: 12)
        EnetWire.commandHeader(
            &bandwidth,
            command: EnetProtocol.commandBandwidthLimit | EnetProtocol.flagAcknowledge,
            channel: 0xFF,
            reliableSequence: 9
        )
        bandwidth.u32BE(0)
        bandwidth.u32BE(0)
        var throttle = ByteWriter(capacity: 16)
        EnetWire.commandHeader(
            &throttle,
            command: EnetProtocol.commandThrottleConfigure | EnetProtocol.flagAcknowledge,
            channel: 0xFF,
            reliableSequence: 10
        )
        throttle.u32BE(5000)
        throttle.u32BE(2)
        throttle.u32BE(2)
        let acks = client.onDatagram(hostDatagram([UInt8](bandwidth.data), [UInt8](throttle.data), sendReliable(seq: 1, [0x01])))
        XCTAssertEqual(acks.count, 3, "a live Sunshine sends a reliable BANDWIDTH_LIMIT a second in; it has to be acknowledged")
        XCTAssertEqual(client.takeReceived(), [Data([0x01])])
        XCTAssertEqual(client.stats.unknownCommands, 0)
        let unknown = client.onDatagram(hostDatagram([0x0D, 0x00, 0x00, 0x00], sendReliable(seq: 2, [0x02])))
        XCTAssertEqual(unknown, [], "command 13 does not exist: the walk stops")
        XCTAssertEqual(client.stats.unknownCommands, 1)
    }

    func testAStaleSessionOrACompressedDatagramIsIgnored() {
        connectAndVerify()
        XCTAssertEqual(client.onDatagram(hostDatagram(session: 1, sendReliable(seq: 1, [0x01]))), [], "another session's datagram")
        var compressed = hostDatagram(sendReliable(seq: 1, [0x01]))
        compressed[0] |= 0x40
        XCTAssertEqual(client.onDatagram(compressed), [])
        XCTAssertEqual(client.takeReceived(), [])
        XCTAssertEqual(client.onDatagram(Data([0x80])), [], "shorter than a header")
    }

    func testDisconnectFromTheHostEndsTheLinkAndALocalDisconnectIsUnsequenced() {
        connectAndVerify()
        var disconnect = ByteWriter(capacity: 8)
        EnetWire.commandHeader(
            &disconnect,
            command: EnetProtocol.commandDisconnect | EnetProtocol.flagUnsequenced,
            channel: 0xFF,
            reliableSequence: 0
        )
        disconnect.u32BE(0)
        _ = client.onDatagram(hostDatagram([UInt8](disconnect.data)))
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertEqual(client.disconnectReason, "peer sent DISCONNECT")
        XCTAssertNil(client.disconnect(), "nothing left to leave")
        connectAndVerify()
        let local = client.disconnect()
        XCTAssertEqual(local.map { Array($0.dropFirst(4)) }, [0x44, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertNil(client.sendReliable(Data([0x01])), "input for a dead session is dropped")
    }

    // MARK: - Sending and the clock

    func testReliableSendsCountFromOneOnChannelZeroAndAreAcknowledgedAway() {
        connectAndVerify()
        let first = client.sendReliable(Data([0xAA, 0xBB]))
        XCTAssertEqual(first.map { Array($0.dropFirst(4)) }, [0x86, 0x00, 0x00, 0x01, 0x00, 0x02, 0xAA, 0xBB])
        XCTAssertEqual(client.sendReliable(Data()).map { Array($0[4 ..< 8]) }, [0x86, 0x00, 0x00, 0x02])
        clock += 10
        _ = client.onDatagram(hostDatagram(ack(channel: 0, seq: 1, sentTime: 0x4321)))
        clock += 600
        let retransmits = client.tick()
        XCTAssertEqual(retransmits.count, 1, "seq 2 is overdue, seq 1 was acknowledged")
        XCTAssertEqual(Array(retransmits[0][4 ..< 8]), [0x86, 0x00, 0x00, 0x02])
        XCTAssertEqual(
            Array(retransmits[0][2 ..< 4]),
            [UInt8(truncatingIfNeeded: clock >> 8), UInt8(truncatingIfNeeded: clock)],
            "re-wrapped with a fresh sent time"
        )
        XCTAssertEqual(client.stats.retransmits, 1)
    }

    func testTheRoundTripEstimateRoundsUpAsTheForkDoes() {
        connectAndVerify()
        clock = 0x4321 + 100
        _ = client.sendReliable(Data([0x01]))
        _ = client.onDatagram(hostDatagram(ack(channel: 0, seq: 1, sentTime: UInt16(truncatingIfNeeded: clock - 100))))
        XCTAssertEqual(client.roundTripMs, 100, "the first sample is the estimate")
        _ = client.sendReliable(Data([0x02]))
        _ = client.onDatagram(hostDatagram(ack(channel: 0, seq: 2, sentTime: UInt16(truncatingIfNeeded: clock - 200))))
        XCTAssertEqual(client.roundTripMs, 113, "variance 50 -> 37 + 25; estimate 100 + ceil(100 / 8)")
        XCTAssertEqual(client.peerRoundTripTimeout(), 113 + min(113, 4 * 62))
        XCTAssertEqual(min(EnetProtocol.timeoutMaximumMs / 5, 9999), 6000, "the timeout caps at a fifth of the maximum")
    }

    func testAnAckFromTheFutureIsIgnoredWhole() {
        connectAndVerify()
        _ = client.sendReliable(Data([0x01]))
        _ = client.onDatagram(hostDatagram(ack(channel: 0, seq: 1, sentTime: UInt16(truncatingIfNeeded: clock + 500))))
        XCTAssertNil(client.roundTripMs)
        clock += 1000
        XCTAssertEqual(client.tick().count, 1, "the command is still owed")
    }

    func testTheGiveUpRuleAfterEnoughResendsAndFiveSeconds() {
        connectAndVerify()
        _ = client.sendReliable(Data([0x01]))
        var attempts = 0
        while client.state == .connected, attempts < 40 {
            clock += 6000
            _ = client.tick()
            attempts += 1
        }
        XCTAssertEqual(client.state, .disconnected)
        XCTAssertTrue(client.disconnectReason?.hasPrefix("peer stopped acknowledging: channel 0 seq 1") ?? false)
        XCTAssertLessThan(attempts, 40)
    }

    func testTheRetransmitTimeoutScalesByTheAttemptsBeforeTheResend() {
        connectAndVerify()
        clock = 10000
        _ = client.sendReliable(Data([0x01]))
        let base = client.peerRoundTripTimeout()
        clock += base
        XCTAssertEqual(client.tick().count, 1, "first resend at the base timeout")
        clock += base - 1
        XCTAssertEqual(client.tick().count, 0, "the second wait is still the base, scaled by one attempt")
        clock += 1
        XCTAssertEqual(client.tick().count, 1)
        clock += 2 * base - 1
        XCTAssertEqual(client.tick().count, 0, "then twice the base")
        clock += 1
        XCTAssertEqual(client.tick().count, 1)
    }

    func testAPingGoesOutOnlyWhenIdleAndAcknowledgedAway() {
        connectAndVerify()
        XCTAssertEqual(client.tick(), [], "just connected: nothing due")
        clock += 500
        let pings = client.tick()
        XCTAssertEqual(pings.count, 1)
        XCTAssertEqual(
            Array(pings[0].dropFirst(4)),
            [0x85, 0xFF, 0x00, 0x02],
            "PING wanting an ack, system channel, seq 2 after the connect's 1"
        )
        clock += 500
        XCTAssertEqual(client.tick(), [], "a ping is outstanding: no second one, the retransmit clock has it")
        _ = client.onDatagram(hostDatagram(ack(channel: 0xFF, seq: 2, sentTime: UInt16(truncatingIfNeeded: clock - 500))))
        XCTAssertEqual(client.tick(), [], "just heard from the peer")
        clock += 499
        XCTAssertEqual(client.tick(), [])
        clock += 1
        XCTAssertEqual(client.tick().count, 1)
    }

    func testTheCommandSizeTableAndThePayloadOffsets() {
        XCTAssertEqual((1 ... 12).map { EnetProtocol.size(ofCommand: UInt8($0)) }, [8, 48, 44, 8, 4, 6, 8, 24, 8, 12, 16, 24])
        XCTAssertNil(EnetProtocol.size(ofCommand: 0))
        XCTAssertNil(EnetProtocol.size(ofCommand: 13))
        XCTAssertEqual(EnetProtocol.dataLengthOffset(ofCommand: EnetProtocol.commandSendReliable), 4)
        XCTAssertEqual(EnetProtocol.dataLengthOffset(ofCommand: EnetProtocol.commandSendUnreliable), 6)
        XCTAssertEqual(EnetProtocol.dataLengthOffset(ofCommand: EnetProtocol.commandSendFragment), 6)
        XCTAssertNil(EnetProtocol.dataLengthOffset(ofCommand: EnetProtocol.commandPing))
    }
}
