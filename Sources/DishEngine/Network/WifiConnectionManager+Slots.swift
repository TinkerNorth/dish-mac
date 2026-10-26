// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The live converge of a session's pads over the per-controller routes
/// (contract §Controller): each index whose descriptor changed is PUT whole,
/// or DELETEd once its pad let go, without rotating the token; the session
/// lives on either way.
extension WifiConnectionManager {

    /// Converge the indices the connection queued, lowest first, then the
    /// host-feature grant they may have moved.
    func syncSlots(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, let connectionId = conn.connectionId else { return }
        conn.setSlotSyncInFlight(true)
        defer { conn.setSlotSyncInFlight(false) }
        refreshControllerTypes(conn, id: conn.id)
        let pending = conn.takePendingIndices()
        for index in pending.sorted() where conn.connectionId == connectionId {
            await syncIndex(index, conn: conn, connectionId: connectionId)
        }
        await convergeHostFeatures(conn)
    }

    /// Ask the satellite again for one bound slot: the Configure binding
    /// page's apply on a binding it already carries, for the host to confirm.
    func resendSlot(_ slotId: String, on conn: WifiConnection) async {
        guard let index = conn.controllerIndex(of: slotId) else { return }
        conn.convergeIndices([index])
        await syncSlots(conn)
    }

    /// The index's pad, PUT whole; an index no pad holds is DELETEd.
    private func syncIndex(_ index: Int, conn: WifiConnection, connectionId: String) async {
        guard let slotId = conn.slotId(at: index), let descriptor = conn.descriptor(for: slotId) else {
            return await deleteSlot(index, conn: conn, connectionId: connectionId)
        }
        await putSlot(descriptor, conn: conn, connectionId: connectionId)
    }

    /// The grant is computed only at the session PUT (contract
    /// §hostFeatures), so a pick that changed the session's desire rides a
    /// whole PUT through the re-key path: the token rotates on the same
    /// socket and the hot path never blips.
    private func convergeHostFeatures(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, conn.wantsMouseControl != conn.mouseControlGranted else { return }
        await rekeySession(conn)
    }

    private func putSlot(_ descriptor: ControllerDescriptor, conn: WifiConnection, connectionId: String) async {
        let server = conn.server
        let resp = await http.putController(
            ip: server.ip,
            port: server.httpPort,
            connectionId: connectionId,
            deviceId: deviceId,
            hmacProof: proofFor(conn.id),
            descriptor: descriptor
        )
        if resp.unauthorized || resp.verdict == .unauthorized {
            handleTerminalAuth(conn.id, loud: false)
            return
        }
        let landed = resp.controller.map(\.slotIsLive) ?? false
        if landed { conn.setLastAppliedEpoch(resp.epoch) }
        recordSlotOutcome(resp.controller, index: descriptor.ctrlIdx, conn: conn)
    }

    /// Best-effort: a failed DELETE self-heals through the enriched-ack
    /// reconcile or the next session PUT.
    private func deleteSlot(_ index: Int, conn: WifiConnection, connectionId: String) async {
        let server = conn.server
        _ = await http.deleteController(
            ip: server.ip,
            port: server.httpPort,
            connectionId: connectionId,
            ctrlIdx: index,
            deviceId: deviceId,
            hmacProof: proofFor(conn.id)
        )
    }
}
