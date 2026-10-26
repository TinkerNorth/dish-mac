// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

extension WifiConnectionManager {

    /// The LAN as one call: the legacy UDP beacon, the Bonjour browse and the
    /// local-network probe in parallel. mDNS reaches subnets that drop
    /// broadcast; the beacon stays for satellites that predate the responder;
    /// the probe names a refusal the other two can only fall silent on. The
    /// app runs the live paths; tests script a LAN.
    struct DiscoveryPaths {
        let scan: @Sendable () async -> ScanResult

        static let live = DiscoveryPaths {
            async let broadcast = Task.detached { LANDiscovery.discover() }.value
            async let mdns = MdnsBrowser.discover()
            async let refused = LocalNetworkProbe.isDenied()
            return await ScanResult(broadcast: broadcast, mdns: mdns, localNetworkDenied: refused)
        }
    }

    /// Run the discovery paths and adopt what they heard. One scan at a time.
    func startDiscovery() {
        guard markScanStarted() else { return }
        let paths = discovery
        Task.detached(priority: .userInitiated) { [weak self] in
            let scan = await paths.scan()
            await MainActor.run { [weak self] in
                self?.adoptScan(scan)
            }
        }
    }

    /// Both discovery paths' raw results, merged lazily by stable id, and
    /// whether macOS refused this app the local network while they ran.
    struct ScanResult {
        let broadcast: [DiscoveredServer]
        let mdns: [DiscoveredServer]
        let localNetworkDenied: Bool

        init(broadcast: [DiscoveredServer], mdns: [DiscoveredServer], localNetworkDenied: Bool = false) {
            self.broadcast = broadcast
            self.mdns = mdns
            self.localNetworkDenied = localNetworkDenied
        }

        init(broadcast: [DiscoveredServer], mdns: BonjourScan.Outcome<DiscoveredServer>, localNetworkDenied: Bool) {
            self.init(
                broadcast: broadcast,
                mdns: mdns.found,
                localNetworkDenied: localNetworkDenied || mdns.localNetworkDenied
            )
        }

        var merged: [DiscoveredServer] {
            mergeDiscovered(broadcast: broadcast, mdns: mdns)
        }

        /// What the scan tells the user: a refusal first, since nothing heard
        /// can be reached; else that nothing answered; nil when something was
        /// heard on an open network.
        var failure: ConnectionFailure? {
            if localNetworkDenied { return .localNetworkDenied }
            return merged.isEmpty ? .noServersFound : nil
        }
    }

    /// Publish a finished scan, re-home remembered satellites whose address
    /// moved, and point idle pool entries at their current endpoint.
    private func adoptScan(_ scan: ScanResult) {
        let merged = scan.merged
        let summary = "broadcast=\(scan.broadcast.count) mdns=\(scan.mdns.count) merged=\(merged.count)"
            + " localNetworkDenied=\(scan.localNetworkDenied)"
        Self.discoveryLog.info("discovery scan: \(summary, privacy: .public)")
        publishScan(merged)
        store.refreshFromDiscovery(merged)
        rehomeIdleConnections(to: merged)
        if let failure = scan.failure {
            events.send(.failure(failure))
        }
    }

    private func rehomeIdleConnections(to merged: [DiscoveredServer]) {
        for server in merged {
            guard let conn = connections[server.id], conn.state == .idle else { continue }
            conn.updateServer(server)
        }
    }
}

/// Merge the two discovery paths by stable id, tagging each server's source.
/// A server heard on both paths becomes `.both`. Name-sorted.
func mergeDiscovered(broadcast: [DiscoveredServer], mdns: [DiscoveredServer]) -> [DiscoveredServer] {
    var byId: [String: DiscoveredServer] = [:]
    for var server in broadcast {
        server.source = .broadcast
        byId[server.id] = server
    }
    for var server in mdns {
        let heardOnBothPaths = byId[server.id] != nil
        server.source = heardOnBothPaths ? .both : .mdns
        byId[server.id] = server
    }
    return byId.values.sorted { $0.name < $1.name }
}
