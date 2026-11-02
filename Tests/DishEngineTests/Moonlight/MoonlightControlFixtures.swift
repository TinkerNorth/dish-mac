// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Foundation
@testable import DishCore
@testable import DishEngine

/// Records what a control session sends; the test hands it the host's datagrams.
final class FakeControlTransport: MoonlightControlTransport {
    var onDatagram: ((Data) -> Void)?
    private let lock = NSLock()
    private var sent: [Data] = []
    private var closedValue = false

    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedValue
    }

    func send(_ datagram: Data) {
        lock.lock()
        sent.append(datagram)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closedValue = true
        lock.unlock()
    }

    func takeSent() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let out = sent
        sent = []
        return out
    }
}

/// The host's side of the control stream, for a test that plays the host
/// to a session sealing under `rikey`.
protocol PlaysMoonlightHost {
    var rikey: Data { get }
}

extension PlaysMoonlightHost {
    /// What the host answers a CONNECT with: peer 0x42 under session 2.
    func verifyConnect(connectId: UInt32 = 7) -> Data {
        var writer = ByteWriter(capacity: 48)
        writer.u16BE(0x8FFF)
        writer.u16BE(0x1111)
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandVerifyConnect | EnetProtocol.flagAcknowledge,
            channel: 0xFF,
            reliableSequence: 1
        )
        writer.u16BE(0x42)
        writer.u8(2)
        writer.u8(2)
        writer.u32BE(1400)
        writer.u32BE(65536)
        writer.u32BE(1)
        writer.u32BE(0)
        writer.u32BE(0)
        writer.u32BE(5000)
        writer.u32BE(2)
        writer.u32BE(2)
        writer.u32BE(connectId)
        return writer.data
    }

    /// A reliable command from the host carrying one sealed control packet.
    func hostPacket(seq: UInt16, plaintext: Data, hostSeq: UInt32) -> Data {
        let packet = MoonlightControlPacket.seal(key: SymmetricKey(data: rikey), seq: hostSeq, plaintext: plaintext) ?? Data()
        var writer = ByteWriter(capacity: 64)
        writer.u16BE(0xA000)
        writer.u16BE(0x2222)
        EnetWire.commandHeader(
            &writer,
            command: EnetProtocol.commandSendReliable | EnetProtocol.flagAcknowledge,
            channel: 0,
            reliableSequence: seq
        )
        writer.u16BE(UInt16(packet.count))
        writer.append(packet)
        return writer.data
    }

    /// The plaintext the session sealed into one sent ENet datagram.
    func plaintext(of datagram: Data) -> Data? {
        let reliable = Data(datagram.dropFirst(4 + 6))
        guard case let .plaintext(plain) = MoonlightControlPacket.open(key: SymmetricKey(data: rikey), packet: reliable) else { return nil }
        return plain
    }
}
