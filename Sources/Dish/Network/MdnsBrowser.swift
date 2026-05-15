// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import Network

/// Discovers Satellite servers advertised over mDNS / Bonjour as the
/// `_satellite._udp.` service type — the modern discovery path that works on
/// subnets where the legacy UDP broadcast beacon ([LANDiscovery]) is dropped
/// (corporate VLANs, IoT segments, Wi-Fi client isolation).
///
/// Pairs with the satellite-side responder in
/// `satellite/src/net/mdns_responder.cpp`, which answers PTR queries for
/// `_satellite._udp.local.` with PTR + SRV + TXT (+ A) records. The TXT
/// record carries the `udp` / `pair` / `http` ports; the resolved endpoint
/// carries the host IP.
///
/// macOS has a first-class mDNS stack, so we use `NWBrowser` rather than a
/// hand-rolled multicast socket — it shares the OS `mDNSResponder` cache and
/// needs no extra entitlement for `_udp.` service discovery on the LAN.
enum MdnsBrowser {

    /// The DNS-SD service type. The trailing dot is required by `NWBrowser`.
    static let serviceType = "_satellite._udp."

    static let defaultTimeoutMs = 4000

    /// Browse for `timeoutMs`, resolving every advertised satellite to a
    /// `DiscoveredServer`. Async — call from a `Task`. Never throws; a missing
    /// mDNS stack or an empty LAN just yields an empty array.
    static func discover(timeoutMs: Int = defaultTimeoutMs) async -> [DiscoveredServer] {
        await withCheckedContinuation { continuation in
            let collector = Collector(continuation: continuation)

            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                using: params
            )
            collector.browser = browser

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    collector.handle(result)
                }
            }
            browser.stateUpdateHandler = { state in
                // A failed browser (no mDNS stack, sandbox denial) should not
                // hang the scan — finish early with whatever we have.
                if case .failed = state { collector.finish() }
            }
            browser.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                collector.finish()
            }
        }
    }

    // MARK: - Collector

    /// Accumulates resolved servers and resumes the continuation exactly once.
    /// `NWBrowser` callbacks + per-service resolution all run on background
    /// queues, so every mutation is funnelled through `lock`.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var servers: [String: DiscoveredServer] = [:] // keyed by id
        private var pending = 0
        private var browseWindowClosed = false
        private var resumed = false
        private var connections: [NWConnection] = []
        private let continuation: CheckedContinuation<[DiscoveredServer], Never>
        var browser: NWBrowser?

        init(continuation: CheckedContinuation<[DiscoveredServer], Never>) {
            self.continuation = continuation
        }

        /// Resolve one browse result. The TXT record gives the ports; an
        /// `NWConnection` to the service endpoint resolves the host IP.
        func handle(_ result: NWBrowser.Result) {
            guard case let .service(name, _, _, _) = result.endpoint else { return }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for key in ["udp", "pair", "http"] {
                    if case let .string(value) = record.getEntry(for: key) { txt[key] = value }
                }
            }

            lock.lock()
            if browseWindowClosed || resumed { lock.unlock()
                return
            }
            pending += 1
            lock.unlock()

            resolveEndpoint(result.endpoint) { [weak self] host in
                guard let self else { return }
                if let host {
                    let server = Self.makeServer(name: name, host: host, txt: txt)
                    self.lock.lock()
                    self.servers[server.id] = server
                    self.lock.unlock()
                }
                self.lock.lock()
                self.pending -= 1
                let done = self.browseWindowClosed && self.pending == 0
                self.lock.unlock()
                if done { self.finish() }
            }
        }

        /// Open a throwaway `NWConnection` purely to resolve the Bonjour
        /// service endpoint to a concrete IPv4 address.
        private func resolveEndpoint(
            _ endpoint: NWEndpoint,
            completion: @escaping (String?) -> Void
        ) {
            let conn = NWConnection(to: endpoint, using: .udp)
            lock.lock()
            connections.append(conn)
            lock.unlock()
            var reported = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if reported { return }
                    reported = true
                    let ip = Self.ipv4(from: conn.currentPath?.remoteEndpoint)
                    conn.cancel()
                    completion(ip)
                case .failed, .cancelled:
                    if reported { return }
                    reported = true
                    completion(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        /// Resume the continuation once — when the browse window closes and
        /// every in-flight resolution has settled (or on browser failure).
        func finish() {
            lock.lock()
            browseWindowClosed = true
            if resumed || pending > 0 { lock.unlock()
                return
            }
            resumed = true
            let out = Array(servers.values)
            let conns = connections
            lock.unlock()
            browser?.cancel()
            for conn in conns {
                conn.cancel()
            }
            continuation.resume(returning: out)
        }

        // MARK: - Helpers

        private static func makeServer(
            name: String,
            host: String,
            txt: [String: String]
        ) -> DiscoveredServer {
            DiscoveredServer(
                name: name.isEmpty ? host : name,
                ip: host,
                udpPort: Int(txt["udp"] ?? "") ?? 9876,
                pairPort: Int(txt["pair"] ?? "") ?? 9878,
                httpPort: Int(txt["http"] ?? "") ?? 9877
            )
        }

        /// Extract a dotted-quad IPv4 string from a resolved endpoint.
        static func ipv4(from endpoint: NWEndpoint?) -> String? {
            guard case let .hostPort(host, _) = endpoint else { return nil }
            switch host {
            case let .ipv4(addr):
                return addr.debugDescription.components(separatedBy: "%").first
            case let .name(name, _):
                return name
            default:
                return nil
            }
        }
    }
}
