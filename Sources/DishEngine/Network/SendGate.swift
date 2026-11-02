// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import DishAtomics
import DishCore
import Foundation

/// The satellite session's send gate: a 32-bit flag one sender holds at a
/// time, taken with a compare-exchange and yielded on while another holds
/// it, the satellite's counter-order rule. A holder claims a counter, seals
/// and sends, so the session's datagrams leave in counter order; a re-key and
/// a socket change hold it too. Nothing waits on it in the kernel.
final class SendGate {
    private let flag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    init() {
        flag.initialize(to: 0)
    }

    deinit {
        flag.deallocate()
    }

    func take() {
        while !dish_atomic_compare_exchange_i32(flag, 0, 1) {
            sched_yield()
        }
    }

    func release() {
        dish_atomic_store_i32(flag, 0)
    }

    /// Whether a sender holds it now; a snapshot, for the tests.
    var isTaken: Bool {
        dish_atomic_load_relaxed_i32(flag) != 0
    }

    func hold<T>(_ body: () throws -> T) rethrows -> T {
        take()
        defer { release() }
        return try body()
    }
}

/// The key and token one session PUT installed, as one object, so a re-key
/// swaps both at once.
final class SessionGeneration: Sendable {
    /// Before any PUT, while the socket is closed: nothing is sent under it.
    static let unkeyed = SessionGeneration(key: SymmetricKey(data: Data(count: ProtocolConstants.cryptoKeySize)), token: 0)

    let key: SymmetricKey
    let token: UInt32

    init(key: SymmetricKey, token: UInt32) {
        self.key = key
        self.token = token
    }
}

/// `sendto`'s shape, so a test can stand in for the socket.
typealias SocketSend = (
    _ fd: Int32,
    _ bytes: UnsafeRawPointer?,
    _ count: Int,
    _ flags: Int32,
    _ address: UnsafePointer<sockaddr>?,
    _ addressLength: socklen_t
) -> Int

extension SatelliteClient {
    /// The socket's own `sendto`.
    static func systemSend(
        _ fd: Int32,
        _ bytes: UnsafeRawPointer?,
        _ count: Int,
        _ flags: Int32,
        _ address: UnsafePointer<sockaddr>?,
        _ addressLength: socklen_t
    ) -> Int {
        Darwin.sendto(fd, bytes, count, flags, address, addressLength)
    }
}
