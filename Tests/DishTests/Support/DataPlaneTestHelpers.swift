// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Shared fixtures for the SatelliteClient data-plane tests: crafted
// server→client datagrams (sealed exactly like the satellite would), a
// client with installed session params, and a tiny bound loopback socket for
// capturing the client's uplink bytes. Everything is deterministic — the
// receive-loop/heartbeat *timers* are exercised end-to-end by the
// FakeSatellite-driven manager tests instead.

import CryptoKit
import Darwin
import DishCore
import Foundation
@testable import Dish

enum DataPlaneTestHelpers {

    static let testKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    static let testToken: UInt32 = 0x0007_A1B2

    /// Seal one server→client datagram byte-exactly like the satellite:
    /// `token(4 BE) | counter(4 BE) | ChaCha20-Poly1305(inner, nonce =
    /// down|0×7|counter, AAD = token)`.
    static func sealDownlink(
        msgType: UInt16,
        payload: Data,
        counter: UInt32,
        key: SymmetricKey = testKey,
        token: UInt32 = testToken
    ) -> Data {
        let inner = PacketCodec.innerFrame(msgType: msgType, payload: payload)
        guard let box = try? SessionCrypto.seal(
            inner,
            key: key,
            direction: .down,
            counter: counter,
            token: token
        ) else { return Data() }
        return PacketCodec.frame(token: token, counter: counter, box: box)
    }

    /// A client with session params installed, aimed at `port` on loopback
    /// (default: the discard port — uplink datagrams vanish harmlessly when a
    /// test only exercises the receive path via `processIncoming`).
    static func makeClient(port: UInt16 = 9) -> SatelliteClient? {
        let client = SatelliteClient()
        guard client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: port,
            token: testToken,
            sessionKey: testKey
        ) else { return nil }
        return client
    }

    /// Bind an ephemeral UDP socket on loopback for capturing the client's
    /// uplink. 2 s receive timeout so a missing datagram fails the test
    /// instead of hanging it.
    static func bindLoopbackSocket() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var rtv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        var bound2 = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound2) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: bound2.sin_port))
    }

    /// Receive one datagram off `fd` (bounded by the socket's RCVTIMEO).
    static func receiveDatagram(fd: Int32) -> Data? {
        var buf = [UInt8](repeating: 0, count: 512)
        var from = sockaddr_in()
        var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bytesRead = buf.withUnsafeMutableBufferPointer { bp -> Int in
            withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, bp.baseAddress, bp.count, 0, sa, &fl)
                }
            }
        }
        guard bytesRead > 0 else { return nil }
        return Data(buf[0 ..< bytesRead])
    }

    /// Open one of the client's uplink datagrams the way the satellite would
    /// (direction `.up`) and split the inner frame.
    static func openUplink(
        _ datagram: Data,
        key: SymmetricKey = testKey,
        token: UInt32 = testToken
    ) -> (counter: UInt32, inner: PacketCodec.InnerMessage)? {
        guard let (header, box) = PacketCodec.parse(datagram), header.token == token,
              let plain = try? SessionCrypto.open(
                  box,
                  key: key,
                  direction: .up,
                  counter: header.counter,
                  token: token
              ),
              let inner = PacketCodec.parseInner(plain) else { return nil }
        return (header.counter, inner)
    }
}
