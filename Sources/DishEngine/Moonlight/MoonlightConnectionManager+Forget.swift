// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

extension MoonlightConnectionManager {
    /// Drop every trace of the host this device holds: the session (a live
    /// one hands its app back first, while the pin that authenticates the
    /// cancel is still there), the record, the bindings, the pin, the facts.
    /// FORGET IS UNILATERAL: the protocol has no unpair verb, so the host
    /// keeps its half until a human removes it there. Serialised, so a
    /// session coming up on the host finishes first and is taken down with
    /// the rest instead of writing the host back once live.
    func forget(hostId: String) {
        serialized { [weak self] in await self?.forgetNow(hostId) }
    }

    private func forgetNow(_ id: String) async {
        epochs[id, default: 0] += 1
        let host = hostFor(id)
        if let conn = connections[id] {
            let live = conn.isStreaming
            attempts[id]?.launched = false
            for pad in conn.pads {
                _ = conn.releasePad(pad.slotId)
            }
            await run(conn.apply(.stopRequested), on: conn)
            if live, let host { _ = await cancelHostApp(host) }
        }
        store.removeHost(id: id)
        for binding in store.bindings(forHost: id) {
            store.removeBinding(slotId: binding.slotId)
        }
        gateway.forgetPin(hostId: id)
        hostFacts.removeValue(forKey: id)
        connections.removeValue(forKey: id)
        attempts.removeValue(forKey: id)
        discoveredHosts.removeAll { $0.id == id }
        verifiedHostIds.remove(id)
        // Moved on again now that everything is gone: a probe that began while
        // the cancel above waited read the epoch after the first move, and
        // would write the host back as verified once answered.
        epochs[id, default: 0] += 1
        publishRemembered()
        publishSessionHosts()
    }
}
