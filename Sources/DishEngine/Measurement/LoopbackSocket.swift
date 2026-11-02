// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin

/// A socket call a loopback peer could not make.
package struct LoopbackSocketError: Error, Equatable {
    package let call: String
    package let code: Int32
}

/// A UDP socket on 127.0.0.1, on a port the system picks, whose receive gives
/// up after 50 ms so the thread reading it notices a stop. The loopback peers
/// of the bench and the lock-law test each own one and close it.
struct LoopbackSocket {
    private static let receiveTimeout = timeval(tv_sec: 0, tv_usec: 50000)
    private static let receiveBufferBytes: Int32 = 4 << 20

    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = try Self.boundSocket()
        do {
            port = try Self.boundPort(fd)
        } catch {
            close(fd)
            throw error
        }
        self.fd = fd
    }

    private static func boundSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LoopbackSocketError(call: "socket", code: errno) }
        var timeout = receiveTimeout
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            close(fd)
            throw LoopbackSocketError(call: "setsockopt", code: errno)
        }
        // Best effort: a bigger buffer only keeps a burst from dropping here.
        var bufferBytes = receiveBufferBytes
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let parsed = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard parsed == 1, bound == 0 else {
            close(fd)
            throw LoopbackSocketError(call: "bind", code: errno)
        }
        return fd
    }

    private static func boundPort(_ fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw LoopbackSocketError(call: "getsockname", code: errno) }
        return UInt16(bigEndian: address.sin_port)
    }
}
