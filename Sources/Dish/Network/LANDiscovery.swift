// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import Foundation

/// Listens on UDP `:9879` for Satellite beacon broadcasts and returns every
/// unique `DiscoveredServer` heard within a timeout. Mirrors
/// `satellite_jni.cpp :: discoverServers`.
enum LANDiscovery {

    static let defaultPort = 9879
    static let defaultTimeoutMs = 4000

    /// Blocking — call from a background queue. The loop exits when the
    /// deadline is reached; each recv has a 300ms timeout so a quiet network
    /// doesn't hang us past `timeoutMs`.
    static func discover(
        port: Int = defaultPort,
        timeoutMs: Int = defaultTimeoutMs
    ) -> [DiscoveredServer] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { close(sock) }

        var reuse: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // macOS requires SO_REUSEPORT as well for multiple listeners (plus it's
        // harmless if we're the only one).
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bindRet = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRet < 0 { return [] }

        var rtv = timeval(tv_sec: 0, tv_usec: 300_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var seen = Set<String>()
        var result: [DiscoveredServer] = []
        var buf = [UInt8](repeating: 0, count: 1024)

        while Date() < deadline {
            var from = sockaddr_in()
            var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.recvfrom(sock, bp.baseAddress, bp.count, 0, sa, &fl)
                    }
                }
            }
            if n <= 0 { continue }
            let str = String(decoding: buf[0 ..< n], as: UTF8.self)
            guard str.contains("\"service\":\"satellite\"") else { continue }

            var ipBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, &from.sin_addr, &ipBytes, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBytes)
            if seen.contains(ip) { continue }
            seen.insert(ip)

            if let server = parseBeacon(json: str, ip: ip) { result.append(server) }
        }
        return result
    }

    /// The beacon JSON can contain extra fields (server version, etc.) so we
    /// decode leniently into our own decoder, then overlay the IP we observed.
    /// Internal (not private) so unit tests can exercise the parse path without
    /// opening a UDP socket.
    static func parseBeacon(json: String, ip: String) -> DiscoveredServer? {
        guard let data = json.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        guard var server = try? dec.decode(DiscoveredServer.self, from: data) else { return nil }
        server.ip = ip
        if server.name.isEmpty { return nil }
        return server
    }
}
