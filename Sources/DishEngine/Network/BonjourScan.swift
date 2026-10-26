// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A bounded Bonjour browse shared by the satellite and the Moonlight scans:
// browse one service type for a window, resolve every advertised endpoint
// to an IPv4 address, and hand each resolved service to a factory. Every
// `NWBrowser` and resolution callback runs on a background queue, so every
// mutation is funnelled through one lock, and the continuation resumes
// exactly once: when the window closes and every resolution has settled, or
// on browser failure. The browse also says whether macOS refused this app
// the local network while it ran, so a scan can say that instead of
// "nothing found".

import Foundation
import Network
import os

enum BonjourScan {
    static let defaultTimeoutMs = 4000
    /// Hard per-endpoint resolution deadline: a Bonjour result whose
    /// `NWConnection` never reaches ready or failed (host vanished mid-browse)
    /// is reported unresolved after this, so it cannot pin the scan open.
    static let resolveTimeoutMs = 3000
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "discovery")

    typealias Factory<Found> = @Sendable (_ name: String, _ host: String, _ txt: [String: String]) -> (id: String, found: Found)

    /// What a browse learned: the services it resolved, and whether macOS
    /// refused this app the local network while it ran: the Local Network
    /// switch under Privacy & Security, or a just-installed build whose
    /// stored permission is not yet in force.
    struct Outcome<Found> {
        let found: [Found]
        let localNetworkDenied: Bool
    }

    /// Never throws; a missing mDNS stack or an empty LAN yields no services.
    static func discover<Found>(
        serviceType: String,
        txtKeys: [String],
        timeoutMs: Int = defaultTimeoutMs,
        make: @escaping Factory<Found>
    ) async -> Outcome<Found> {
        await withCheckedContinuation { continuation in
            let collector = Collector(continuation: continuation, txtKeys: txtKeys, make: make)
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
            collector.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    collector.handle(result)
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case let .waiting(error):
                    collector.browserWaiting(error)
                case let .failed(error):
                    // A failed browser (no mDNS stack, a sandbox denial) must not hang the scan.
                    log.warning("mDNS browser failed: \(String(describing: error), privacy: .public)")
                    collector.finish()
                case .setup, .ready, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                collector.finish()
            }
        }
    }

    /// The resolving connection's parameters: UDP over IPv4 only. The data
    /// plane dials IPv4 literals, and a dual-stack host (Windows answers
    /// AAAA for its own name) would otherwise resolve to its link-local IPv6
    /// address and be dropped.
    static func resolveParameters() -> NWParameters {
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return params
    }

    /// A dotted-quad IPv4 string from a resolved endpoint. The receivers feed
    /// it to `inet_pton(AF_INET, …)`, so an IPv6-only result and an unresolved
    /// name are both rejected with a log line rather than returned.
    static func ipv4(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(addr):
            return addr.debugDescription.components(separatedBy: "%").first
        case let .ipv6(addr):
            log.warning("mDNS result dropped — IPv6-only endpoint \(addr.debugDescription, privacy: .public), receiver is IPv4-only")
            return nil
        case let .name(name, _):
            log.warning("mDNS result dropped — endpoint resolved to unresolved hostname \(name, privacy: .public), not an IPv4 literal")
            return nil
        @unknown default:
            return nil
        }
    }

    /// Accumulates resolved services and resumes the continuation exactly once.
    private final class Collector<Found>: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [String: Found] = [:]
        private var pending = 0
        private var browseWindowClosed = false
        private var resumed = false
        private var localNetworkDenied = false
        private var connections: [NWConnection] = []
        private let continuation: CheckedContinuation<Outcome<Found>, Never>
        private let txtKeys: [String]
        private let make: Factory<Found>
        var browser: NWBrowser?

        init(continuation: CheckedContinuation<Outcome<Found>, Never>, txtKeys: [String], make: @escaping Factory<Found>) {
            self.continuation = continuation
            self.txtKeys = txtKeys
            self.make = make
        }

        /// One browse result: the TXT keys asked for, then the endpoint resolved to a host.
        func handle(_ result: NWBrowser.Result) {
            guard case let .service(name, _, _, _) = result.endpoint else { return }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for key in txtKeys {
                    if case let .string(value) = record.getEntry(for: key) { txt[key] = value }
                }
            }
            lock.lock()
            if browseWindowClosed || resumed {
                lock.unlock()
                return
            }
            pending += 1
            lock.unlock()
            resolveEndpoint(result.endpoint) { [weak self] host in
                guard let self else { return }
                if let host {
                    let made = make(name, host, txt)
                    lock.lock()
                    found[made.id] = made.found
                    lock.unlock()
                }
                lock.lock()
                pending -= 1
                let done = browseWindowClosed && pending == 0
                lock.unlock()
                if done { finish() }
            }
        }

        /// A browser waiting on policy will not recover within the window:
        /// note the refusal and close. Any other wait is left to the window.
        func browserWaiting(_ error: NWError) {
            BonjourScan.log.warning("mDNS browser waiting: \(String(describing: error), privacy: .public)")
            guard LocalNetworkProbe.isLocalNetworkDenial(error) else { return }
            noteLocalNetworkDenial()
            finish()
        }

        private func noteLocalNetworkDenial() {
            lock.lock()
            localNetworkDenied = true
            lock.unlock()
        }

        /// A throwaway `NWConnection` purely to resolve the service endpoint to
        /// an address, reported exactly once: the state handler, a refusal on
        /// its path, or the hard deadline, whichever fires first.
        private func resolveEndpoint(_ endpoint: NWEndpoint, completion: @escaping (String?) -> Void) {
            let conn = NWConnection(to: endpoint, using: BonjourScan.resolveParameters())
            lock.lock()
            connections.append(conn)
            lock.unlock()
            let reportLock = NSLock()
            var reported = false
            func reportOnce(_ ip: String?) {
                reportLock.lock()
                let first = !reported
                reported = true
                reportLock.unlock()
                guard first else { return }
                conn.cancel()
                completion(ip)
            }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    reportOnce(BonjourScan.ipv4(from: conn.currentPath?.remoteEndpoint))
                case let .waiting(error):
                    self?.resolveWaiting(conn, error: error, reportOnce: reportOnce)
                case let .failed(error):
                    BonjourScan.log.warning("mDNS resolve failed: \(String(describing: error), privacy: .public)")
                    reportOnce(nil)
                case .cancelled:
                    reportOnce(nil)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            conn.pathUpdateHandler = { [weak self] path in
                guard LocalNetworkProbe.isLocalNetworkDenial(path) else { return }
                self?.resolveRefused(reportOnce: reportOnce)
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(BonjourScan.resolveTimeoutMs)) {
                reportOnce(nil)
            }
        }

        /// A wait on policy is a refusal, reported at once; any other wait (a
        /// slow host) is left to the hard deadline.
        private func resolveWaiting(_ conn: NWConnection, error: NWError, reportOnce: (String?) -> Void) {
            let path = conn.currentPath
            BonjourScan.log.warning(
                "mDNS resolve waiting: \(String(describing: error), privacy: .public); path \(String(describing: path), privacy: .public)"
            )
            if LocalNetworkProbe.isLocalNetworkDenial(path) { resolveRefused(reportOnce: reportOnce) }
        }

        private func resolveRefused(reportOnce: (String?) -> Void) {
            BonjourScan.log.warning("mDNS resolve refused: macOS denies this app the local network")
            noteLocalNetworkDenial()
            reportOnce(nil)
        }

        /// Once: when the window closes and every resolution has settled, or
        /// on failure. The first close cancels the browser and every pending
        /// connection, so a wedged one fails fast instead of holding the scan.
        func finish() {
            lock.lock()
            let firstClose = !browseWindowClosed
            browseWindowClosed = true
            if resumed {
                lock.unlock()
                return
            }
            let conns = connections
            let activeBrowser = browser
            if pending > 0 {
                lock.unlock()
                if firstClose {
                    activeBrowser?.cancel()
                    conns.forEach { $0.cancel() }
                }
                return
            }
            resumed = true
            let out = Outcome(found: Array(found.values), localNetworkDenied: localNetworkDenied)
            lock.unlock()
            activeBrowser?.cancel()
            conns.forEach { $0.cancel() }
            let summary = "\(out.found.count) service(s), local network denied: \(out.localNetworkDenied)"
            BonjourScan.log.info("mDNS browse complete — \(summary, privacy: .public)")
            continuation.resume(returning: out)
        }
    }
}
