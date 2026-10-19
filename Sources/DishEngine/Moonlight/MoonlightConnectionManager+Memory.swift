// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// What the dish remembers about hosts: interest and trust, kept apart; the
/// app a session settled on; the pick per host; the pad bindings.
extension MoonlightConnectionManager {
    /// Record a host the user committed to without claiming it is paired. A
    /// host that lives only in the discovery list disappears the moment a
    /// browse misses it, and a binding pointing at one loses its session.
    func rememberInterest(_ host: MoonlightHost) {
        guard store.host(id: host.id) == nil else { return }
        rememberPaired(host, paired: false)
    }

    /// The same, for a host known only by id.
    func rememberInterest(hostId: String) {
        guard let host = hostFor(hostId) else { return }
        rememberInterest(host)
    }

    /// Remember which app the session settled on, so the next binding can say
    /// it is joining it. A host with no record yet gets one, as interest.
    func rememberApp(hostId: String, appId: String, appName: String) {
        guard var record = store.host(id: hostId) else {
            guard let host = hostFor(hostId) else { return }
            rememberPaired(host, appId: appId, appName: appName, paired: false)
            return
        }
        record.lastAppId = appId
        record.lastAppName = appName
        store.put(record)
        publishRemembered()
    }

    /// The emulated-type pick for a host, Auto by default.
    func rememberedEmulatedType(hostId: String) -> UInt8 {
        MoonlightPadRules.migrateStoredType(store.host(id: hostId)?.emulatedType ?? Int(MoonlightControllerType.auto))
    }

    func setEmulatedType(hostId: String, type: UInt8) {
        guard var record = store.host(id: hostId) else { return }
        record.emulatedType = Int(type)
        store.put(record)
        publishRemembered()
    }

    func rememberedAppId(hostId: String) -> String {
        store.host(id: hostId)?.lastAppId ?? ""
    }

    func rememberedAppName(hostId: String) -> String {
        store.host(id: hostId)?.lastAppName ?? ""
    }

    /// The standing binding of a pad, kept across restarts; the hub writes and drops it.
    func rememberBinding(slotId: String, hostId: String, controllerType: Int) {
        store.putBinding(RememberedMoonlightBinding(slotId: slotId, hostId: hostId, controllerType: controllerType))
    }

    func forgetBinding(slotId: String) {
        store.removeBinding(slotId: slotId)
    }

    var rememberedBindings: [RememberedMoonlightBinding] {
        store.bindings()
    }

    /// Write the host's record. Only a pairing names the machine, with
    /// `answeredUniqueId`: the one the host answered as when the pairing
    /// began. Every other write keeps the machine remembered. Trust only
    /// ever climbs here: a launch on a paired host must not demote it, and
    /// interest must not promote it.
    func rememberPaired(
        _ host: MoonlightHost,
        appId: String? = nil,
        appName: String? = nil,
        paired: Bool,
        answeredUniqueId: String = ""
    ) {
        let known = store.host(id: host.id)
        var record = RememberedMoonlightHost(host: host, paired: paired || known?.paired == true)
        record.uniqueId = answeredUniqueId.isEmpty ? (known?.uniqueId ?? "") : answeredUniqueId
        record.lastAppId = appId ?? known?.lastAppId ?? ""
        record.lastAppName = appName ?? known?.lastAppName ?? ""
        record.emulatedType = known?.emulatedType ?? Int(MoonlightControllerType.auto)
        store.put(record)
        publishRemembered()
    }

    /// The first uniqueid a remembered host answers with is kept: the witness
    /// that later tells the machine this client paired with from another one
    /// behind the same address.
    func keepFirstUniqueId(_ hostId: String, _ info: MoonlightServerInfo) {
        guard var record = store.host(id: hostId), record.uniqueId.isEmpty, !info.uniqueId.isEmpty else { return }
        record.uniqueId = info.uniqueId
        store.put(record)
        publishRemembered()
    }

    func publishRemembered() {
        rememberedHosts = store.hosts()
    }
}
