// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Whether macOS lets this process reach the local network. The Local Network
// permission is enforced in the kernel, flow by flow; a Bonjour resolution it
// blocks only stalls, and a beacon socket it blocks only stays silent, so the
// one reading that names the refusal is a direct flow to an address on the
// LAN: the default gateway. Allowed, a UDP flow to it is ready at once;
// refused, it waits on a path whose unsatisfied reason says so.

import dnssd
import Foundation
import Network
import os
import SystemConfiguration

enum LocalNetworkProbe {
    static let defaultTimeoutMs = 1500
    /// The discard port: nothing is sent, the flow only has to be allowed.
    static let probePort: UInt16 = 9
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "discovery")

    /// The IPv4 default gateway from the system's dynamic store; nil off the
    /// network, when there is no local network to be refused.
    static func defaultGateway() -> String? {
        let store = SCDynamicStoreCreate(nil, "com.tinkernorth.dish.discovery" as CFString, nil, nil)
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return global?["Router"] as? String
    }

    /// True when macOS refuses this process a flow to `gateway`. No gateway,
    /// and a probe that settles neither way within the deadline, both read as
    /// not refused: only a refusal the path names is one.
    static func isDenied(gateway: String? = defaultGateway(), timeoutMs: Int = defaultTimeoutMs) async -> Bool {
        guard let gateway, let port = NWEndpoint.Port(rawValue: probePort) else { return false }
        return await withCheckedContinuation { continuation in
            let probe = Probe(continuation: continuation, gateway: gateway, port: port)
            probe.start(timeoutMs: timeoutMs)
        }
    }

    /// Whether a path says macOS refused this app the local network.
    static func isLocalNetworkDenial(_ path: NWPath?) -> Bool {
        path?.unsatisfiedReason == .localNetworkDenied
    }

    /// Whether a browser error is the mDNS daemon refusing a browse on
    /// local-network policy, the way a platform that enforces the permission
    /// at the browse reports a denial.
    static func isLocalNetworkDenial(_ error: NWError) -> Bool {
        if case let .dns(code) = error { return Int(code) == kDNSServiceErr_PolicyDenied }
        return false
    }

    /// One UDP flow to the gateway, settled exactly once: ready, a refusal on
    /// its path, any other end, or the deadline.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private let continuation: CheckedContinuation<Bool, Never>
        private let connection: NWConnection

        init(continuation: CheckedContinuation<Bool, Never>, gateway: String, port: NWEndpoint.Port) {
            self.continuation = continuation
            connection = NWConnection(host: NWEndpoint.Host(gateway), port: port, using: .udp)
        }

        /// The handlers and the deadline hold the probe until it settles;
        /// settling releases them.
        func start(timeoutMs: Int) {
            connection.stateUpdateHandler = { state in self.handle(state) }
            connection.pathUpdateHandler = { path in
                if LocalNetworkProbe.isLocalNetworkDenial(path) { self.settle(denied: true) }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                self.settle(denied: false)
            }
        }

        private func handle(_ state: NWConnection.State) {
            switch state {
            case .ready:
                settle(denied: false)
            case let .waiting(error):
                let path = connection.currentPath
                let summary = "\(String(describing: error)); path \(String(describing: path))"
                LocalNetworkProbe.log.warning("local network probe waiting: \(summary, privacy: .public)")
                if LocalNetworkProbe.isLocalNetworkDenial(path) { settle(denied: true) }
            case .failed, .cancelled:
                settle(denied: false)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }

        private func settle(denied: Bool) {
            lock.lock()
            let first = !settled
            settled = true
            lock.unlock()
            guard first else { return }
            if denied { LocalNetworkProbe.log.warning("local network probe refused: macOS denies this app the local network") }
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: denied)
        }
    }
}
