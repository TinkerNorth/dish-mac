// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// What a support report reads of each satellite: the host's own view of
/// the connection, asked once per live link, and the client's own view of
/// the session. Asking changes nothing: a refusal here is a fact for the
/// file, never a reason to drop the key.
extension WifiConnectionManager {

    /// Every live link asked at once, each within `timeout`; a link with no
    /// session is not asked.
    func connectionSnapshots(timeout: TimeInterval = HostSnapshotPolicy.timeoutSeconds) async -> [String: HostSnapshotVerdict] {
        let live = connections.values.filter(\.hasLiveSession).map(\.id)
        return await withTaskGroup(of: (String, HostSnapshotVerdict?).self) { group in
            for id in live {
                group.addTask { @MainActor in await (id, self.connectionSnapshot(id, timeout: timeout)) }
            }
            var verdicts: [String: HostSnapshotVerdict] = [:]
            for await (id, verdict) in group {
                verdicts[id] = verdict
            }
            return verdicts
        }
    }

    /// Nil when the link went before it could be asked; a Satellite older
    /// than the route, by its probe's version, is not asked.
    private func connectionSnapshot(_ id: String, timeout: TimeInterval) async -> HostSnapshotVerdict? {
        guard let conn = connections[id], let connectionId = conn.connectionId else { return nil }
        let version = capabilities[id]?.serverVersion ?? ""
        guard satelliteAnswersDiagnostics(serverVersion: version) else { return .failed(.olderSatellite) }
        let server = conn.server
        let proof = await proofFor(id)
        let reply = await http.getConnectionDiagnostics(
            ip: server.ip,
            port: server.httpPort,
            connectionId: connectionId,
            deviceId: deviceId,
            hmacProof: proof,
            timeout: timeout
        )
        return hostSnapshotVerdict(reply)
    }

    /// The satellite's capabilities and catalog as last fetched, for the
    /// stand-in; nil for a satellite never probed.
    func capabilitiesFacts(_ id: String) -> SatelliteCapabilitiesFacts? {
        capabilities[id].map { satelliteCapabilitiesFacts($0, catalog: catalogs[id]) }
    }

    /// The client's own view of the session; nil while there is none.
    /// `records` names each slot's controller record by slot id.
    func sessionFacts(_ id: String, records: [String: String]) -> BundleSessionFacts? {
        guard let conn = connections[id], conn.hasLiveSession else { return nil }
        let slugs = catalogSlugs(catalogs[id])
        let slots = conn.boundSlotIds.compactMap { slotId in
            conn.descriptor(for: slotId).map { descriptor in
                sessionSlot(
                    descriptor,
                    record: records[slotId],
                    answer: applyAnswers.state[SlotKey(connectionId: id, slotId: slotId)],
                    slugs: slugs
                )
            }
        }
        return BundleSessionFacts(
            slots: slots.sorted { $0.index < $1.index },
            ack: conn.lastHeartbeatAck,
            latency: conn.client?.latencySummary() ?? HostSessionFacts.resting(id: id).latency,
            counts: conn.client?.tally.counts() ?? WireCounts()
        )
    }
}

/// The catalog's slug for each type it offers.
func catalogSlugs(_ catalog: CatalogDTO?) -> [Int: String] {
    Dictionary((catalog?.controllerTypes ?? []).map { ($0.id, $0.slug) }) { first, _ in first }
}

/// One slot as asked and as answered; the answer's fields are nil until the
/// satellite gave one.
func sessionSlot(_ descriptor: ControllerDescriptor, record: String?, answer: SlotApplyAnswer?, slugs: [Int: String]) -> BundleSessionSlot {
    BundleSessionSlot(
        index: descriptor.ctrlIdx,
        record: record,
        requestedType: controllerTypeName(Int(descriptor.type), slugs: slugs),
        appliedType: answer.map { controllerTypeName($0.appliedType, slugs: slugs) },
        backend: answer?.backend,
        result: answer?.result,
        touchpadMode: descriptor.touchpadMode.wireName
    )
}
