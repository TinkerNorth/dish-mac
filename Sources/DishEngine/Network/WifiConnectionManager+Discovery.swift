// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

extension WifiConnectionManager {

    /// Run the two discovery paths in parallel: the legacy UDP beacon and
    /// mDNS. mDNS reaches subnets that drop broadcast; the beacon stays for
    /// satellites that predate the responder. One scan at a time.
    func startDiscovery() {
        guard markScanStarted() else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            async let broadcast = Task.detached { LANDiscovery.discover() }.value
            async let mdns = MdnsBrowser.discover()
            let scan = await ScanResult(broadcast: broadcast, mdns: mdns)
            await MainActor.run { [weak self] in
                self?.adoptScan(scan)
            }
        }
    }

    /// Both discovery paths' raw results, merged lazily by stable id.
    struct ScanResult {
        let broadcast: [DiscoveredServer]
        let mdns: [DiscoveredServer]

        var merged: [DiscoveredServer] {
            mergeDiscovered(broadcast: broadcast, mdns: mdns)
        }
    }

    /// Publish a finished scan, re-home remembered satellites whose address
    /// moved, and point idle pool entries at their current endpoint.
    private func adoptScan(_ scan: ScanResult) {
        let merged = scan.merged
        let summary = "broadcast=\(scan.broadcast.count) mdns=\(scan.mdns.count) merged=\(merged.count)"
        Self.discoveryLog.info("discovery scan: \(summary, privacy: .public)")
        publishScan(merged)
        store.refreshFromDiscovery(merged)
        rehomeIdleConnections(to: merged)
        if merged.isEmpty {
            events.send(.failure(.noServersFound))
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
