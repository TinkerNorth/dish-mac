// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import Foundation

/// Blocking TCP pair handshake with a Satellite server. Mirrors
/// `satellite_jni.cpp :: pair`. Sends a single JSON line and reads the
/// server's JSON reply.
enum PairingClient {

    struct Request: Encodable {
        let deviceId: String
        let deviceName: String
        let pin: String
    }

    /// Classifies a `PairResponse` so callers can distinguish "server moved /
    /// went offline" (network failure) from "server refused our PIN / shared
    /// key" (auth failure). Mirrors the same distinction Android's
    /// `SatelliteConnectionManager` makes after dish-android PR #43.
    enum Outcome: Equatable {
        case success(sharedKeyHex: String)
        case authRequired
        case unreachable(String)
    }

    /// Pure classifier. Driven only by fields on the response so it's
    /// trivially unit-testable.
    static func classify(_ response: PairResponse) -> Outcome {
        if response.ok, let key = response.sharedKey, !key.isEmpty {
            return .success(sharedKeyHex: key)
        }
        if response.reachable {
            return .authRequired
        }
        return .unreachable(response.error ?? "Server unreachable")
    }

    /// Call from a background queue. Returns the parsed `PairResponse`.
    /// `reachable` is set to `true` iff we received and parsed a JSON body
    /// from the server; every network-level failure path returns `reachable
    /// = false` so the caller can surface a clean "Server unreachable —
    /// has it moved networks?" message instead of trapping the user behind
    /// a PIN prompt they can't satisfy.
    static func pair(
        ip: String,
        port: Int,
        deviceId: String,
        deviceName: String,
        pin: String
    ) -> PairResponse {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { return PairResponse(ok: false, error: "socket failed") }
        defer { close(sock) }

        // Non-blocking connect + 4s select timeout, then back to blocking I/O
        // so send/recv are simple. Same shape as the Android version.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        if inet_pton(AF_INET, ip, &addr.sin_addr) != 1 {
            return PairResponse(ok: false, error: "bad ip")
        }

        let connectRet = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectRet != 0, errno != EINPROGRESS {
            return PairResponse(ok: false, error: "connect failed")
        }
        if connectRet != 0 {
            var tv = timeval(tv_sec: 4, tv_usec: 0)
            var wset = fd_set()
            fdZero(&wset)
            fdSet(sock, &wset)
            let sel = select(sock + 1, nil, &wset, nil, &tv)
            if sel <= 0 { return PairResponse(ok: false, error: "connect timeout") }
            var sockerr: Int32 = 0
            var sl = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockerr, &sl)
            if sockerr != 0 { return PairResponse(ok: false, error: "connect refused") }
        }
        _ = fcntl(sock, F_SETFL, flags & ~O_NONBLOCK)

        guard let body = try? JSONEncoder().encode(
            Request(deviceId: deviceId, deviceName: deviceName, pin: pin)
        ) else { return PairResponse(ok: false, error: "encode failed") }

        _ = body.withUnsafeBytes { ptr in
            Darwin.send(sock, ptr.baseAddress, ptr.count, 0)
        }

        var rtv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 512)
        let bytesRead = buf.withUnsafeMutableBufferPointer { bp in
            Darwin.recv(sock, bp.baseAddress, bp.count, 0)
        }
        if bytesRead <= 0 { return PairResponse(ok: false, error: "no response") }

        let data = Data(buf[0 ..< bytesRead])
        if var parsed = try? JSONDecoder().decode(PairResponse.self, from: data) {
            // Successful round-trip with the server — even ok=false counts as
            // reachable for the purposes of distinguishing offline-vs-auth.
            parsed.reachable = true
            return parsed
        }
        return PairResponse(ok: false, error: "malformed response")
    }
}

// MARK: - fd_set helpers (Darwin's fd_set is opaque in Swift)

@inline(__always)
private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

@inline(__always)
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = fd % 32
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bound in
            bound[intOffset] |= mask
        }
    }
}
