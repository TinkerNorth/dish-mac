// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The session's lock holds the ENet bookkeeping and nothing else: a report
/// never waits on the receive path's decrypt, the host is acknowledged and
/// the clock ticks while a send is sealing, the host's events still come out
/// in the order they came, and senders on many threads never share a control
/// sequence. Every wait is bounded, so a lock held across the crypto fails
/// these instead of hanging them.
final class MoonlightControlSessionLockTests: XCTestCase, PlaysMoonlightHost {
    let rikey = Data((0 ..< 16).map { UInt8($0 * 7 + 3) })
    private let clock = AtomicInt(100_000)
    private let transport = FakeControlTransport()
    private let events = LockedBox<[MoonlightEvent]>([])

    func testAReportSentWhileTheHostsPacketIsOpeningWaitsOnlyForTheBookkeeping() {
        let decrypt = Hold()
        let aes = MoonlightControlCipher.aesGcm(rikey: rikey)
        let session = makeSession(MoonlightControlCipher(seal: aes.seal) { packet in
            decrypt.pass()
            return aes.open(packet)
        })
        let connected = connect(session)
        XCTAssertTrue(connected)
        XCTAssertFalse(transport.takeSent().isEmpty, "the CONNECT went out")
        let transport = transport
        let packet = hostPacket(seq: 1, plaintext: rumble(controller: 1, low: 0x1234, high: 0xFF00), hostSeq: 0)
        let delivery = DispatchQueue(label: "test.moonlight.transport")
        delivery.async { transport.onDatagram?(packet) }
        XCTAssertEqual(decrypt.entered.wait(timeout: .now() + 2), .success, "the receive path is opening the host's packet")
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.sendControllerState(MoonlightInput.PadFrame(controller: 0, activeMask: 1, rightX: 7))
            sent.signal()
        }
        XCTAssertEqual(sent.wait(timeout: .now() + 2), .success, "the report did not wait for the decrypt")
        let midway = transport.takeSent()
        XCTAssertEqual(midway.count, 2, "the host's packet acknowledged before it was opened, then the report")
        XCTAssertEqual(midway.last.flatMap(plaintext(of:)), MoonlightInput.controllerMulti(.init(controller: 0, activeMask: 1, rightX: 7)))
        XCTAssertEqual(events.get(), [], "the event waits for its open")
        decrypt.release()
        delivery.sync {}
        XCTAssertEqual(events.get(), [.rumble(controller: 1, low: 0x1234, high: 0xFF00)])
    }

    func testTheHostIsAcknowledgedAndTheClockTicksWhileAReportIsSealing() {
        let sealing = Hold()
        let armed = AtomicBool(false)
        let aes = MoonlightControlCipher.aesGcm(rikey: rikey)
        let session = makeSession(MoonlightControlCipher(seal: { seq, plaintext in
            if armed.get() { sealing.pass() }
            return aes.seal(seq, plaintext)
        }, open: aes.open))
        let connected = connect(session)
        XCTAssertTrue(connected)
        XCTAssertFalse(transport.takeSent().isEmpty, "the CONNECT went out")
        armed.set(true)
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.sendControllerState(MoonlightInput.PadFrame(controller: 0, activeMask: 1, rightX: 9))
            sent.signal()
        }
        XCTAssertEqual(sealing.entered.wait(timeout: .now() + 2), .success, "the report is sealing")
        let transport = transport
        let clock = clock
        let packet = hostPacket(seq: 1, plaintext: rgbLed(controller: 0, red: 1, green: 2, blue: 3), hostSeq: 0)
        let ticked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.onDatagram?(packet)
            clock.set(100_500)
            session.tick()
            ticked.signal()
        }
        XCTAssertEqual(ticked.wait(timeout: .now() + 2), .success, "neither the receive path nor the tick waited for the seal")
        let midway = transport.takeSent()
        XCTAssertEqual(midway.first.map { $0[4] }, EnetProtocol.commandAcknowledge, "the host's packet acknowledged")
        XCTAssertEqual(midway.compactMap(plaintext(of:)), [MoonlightInput.periodicPing()], "the keepalive sealed and sent")
        XCTAssertEqual(events.get(), [.rgbLed(controller: 0, red: 1, green: 2, blue: 3)])
        sealing.release()
        XCTAssertEqual(sent.wait(timeout: .now() + 2), .success)
        let report = transport.takeSent()
        XCTAssertEqual(report.compactMap(plaintext(of:)), [MoonlightInput.controllerMulti(.init(controller: 0, activeMask: 1, rightX: 9))])
    }

    func testTheHostsEventsComeOutInTheOrderTheyCameWhileReportsGoOut() {
        let session = makeSession(.aesGcm(rikey: rikey))
        let connected = connect(session)
        XCTAssertTrue(connected)
        let transport = transport
        let lows = (1 ... 40).map { UInt16($0) }
        let packets = lows.enumerated().map { index, low in
            hostPacket(seq: UInt16(index + 1), plaintext: rumble(controller: 0, low: low, high: 0), hostSeq: UInt32(index))
        }
        let reports = DispatchGroup()
        DispatchQueue.global().async(group: reports) {
            for frame in 0 ..< 200 {
                session.sendControllerState(MoonlightInput.PadFrame(controller: 0, activeMask: 1, rightX: Int16(frame)))
            }
        }
        let delivery = DispatchQueue(label: "test.moonlight.transport")
        for packet in packets {
            delivery.async { transport.onDatagram?(packet) }
        }
        delivery.sync {}
        XCTAssertEqual(reports.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(events.get(), lows.map { MoonlightEvent.rumble(controller: 0, low: $0, high: 0) })
    }

    func testSendersOnManyThreadsNeverShareAControlSequenceOrAnEnetSequence() {
        let session = makeSession(.aesGcm(rikey: rikey))
        let connected = connect(session)
        XCTAssertTrue(connected)
        XCTAssertFalse(transport.takeSent().isEmpty, "the CONNECT went out")
        let threads = 4
        let each = 250
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for frame in 0 ..< each {
                session.sendControllerState(MoonlightInput.PadFrame(controller: UInt8(thread), activeMask: 0xF, rightX: Int16(frame)))
            }
        }
        let sent = transport.takeSent()
        XCTAssertEqual(sent.count, threads * each)
        XCTAssertEqual(Set(sent.map(enetSequence)), Set(1 ... UInt16(threads * each)), "each ENet sequence once")
        XCTAssertEqual(Set(sent.map(controlSequence)), Set(0 ..< UInt32(threads * each)), "each control sequence once: no IV twice")
        XCTAssertEqual(sent.compactMap(plaintext(of:)).count, sent.count, "every packet opens under the sequence it carries")
    }

    // MARK: - Fixtures

    private func makeSession(_ cipher: MoonlightControlCipher) -> MoonlightControlSession {
        let clock = clock
        let events = events
        return MoonlightControlSession(
            cipher: cipher,
            connectData: 0xFE88_1C39,
            transport: transport,
            now: { Int64(clock.get()) },
            random: { 7 },
            onEvent: { event in events.mutate { $0.append(event) } },
            onClosed: {}
        )
    }

    /// The handshake, the test answering as the host; false when it does not
    /// settle within five seconds.
    private func connect(_ session: MoonlightControlSession) -> Bool {
        let connected = AtomicBool(false)
        let settled = DispatchSemaphore(value: 0)
        Task {
            await connected.set(session.connect())
            settled.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        transport.onDatagram?(verifyConnect())
        guard settled.wait(timeout: .now() + 5) == .success else { return false }
        return connected.get()
    }
}

/// Stops the first caller of `pass` until the test releases it.
private final class Hold {
    let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let first = AtomicBool(true)

    func pass() {
        guard first.getAndSet(false) else { return }
        entered.signal()
        released.wait()
    }

    func release() {
        released.signal()
    }
}

/// RUMBLE_DATA as a host sends it: an unused word, the pad, the low and the high motor.
private func rumble(controller: UInt16, low: UInt16, high: UInt16) -> Data {
    var writer = ByteWriter(capacity: 14)
    writer.u16LE(MoonlightProtocol.eventRumbleData)
    writer.u16LE(10)
    writer.u32LE(0)
    writer.u16LE(controller)
    writer.u16LE(low)
    writer.u16LE(high)
    return writer.data
}

private func rgbLed(controller: UInt16, red: UInt8, green: UInt8, blue: UInt8) -> Data {
    var writer = ByteWriter(capacity: 9)
    writer.u16LE(MoonlightProtocol.eventRgbLed)
    writer.u16LE(5)
    writer.u16LE(controller)
    writer.u8(red)
    writer.u8(green)
    writer.u8(blue)
    return writer.data
}

/// A sent datagram's reliable sequence: the header, then the command and channel bytes.
private func enetSequence(_ datagram: Data) -> UInt16 {
    UInt16(datagram[6]) << 8 | UInt16(datagram[7])
}

/// A sent datagram's control sequence, little-endian behind the packet's type and length.
private func controlSequence(_ datagram: Data) -> UInt32 {
    (0 ..< 4).reduce(UInt32(0)) { sum, index in sum | UInt32(datagram[14 + index]) << UInt32(index * 8) }
}
