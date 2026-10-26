// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// Bindings survive a restart, as the desktops' standing bindings and
/// Android's Moonlight ones do: a remembered binding is bound again without
/// the user once its pad is attached and its destination is known here (a
/// satellite in the pool, a Moonlight host on record), whichever comes last.
extension AppModel {

    /// Settled, so the pads, the pool and the hosts read are the emitted ones.
    func observeBindingMemory() {
        let pads = input.$slots.map { _ in () }
        let satellites = wifi.$connections.map { _ in () }
        let hosts = moonlight.$rememberedHosts.map { _ in () }
        Publishers.Merge3(pads, satellites, hosts)
            .afterMutationSettles()
            .sink { [weak self] in self?.restoreStandingBindings() }
            .store(in: &cancellables)
    }

    private func restoreStandingBindings() {
        let due = hub.takeDueStandingBindings(
            present: Set(input.slots.map(\.id)),
            satellites: Set(wifi.connections.keys),
            hosts: Set(moonlight.rememberedHosts.map(\.id))
        )
        for standing in due {
            restore(standing)
        }
    }

    /// The pick first, so the bind already carries the type it names.
    private func restore(_ standing: StandingBinding) {
        let key = SlotKey(connectionId: standing.connectionId, slotId: standing.slotId)
        if let type = standing.emulatedType {
            wifi.typeOverrides.setType(type, for: key)
        }
        bind(slotId: standing.slotId, connectionId: standing.connectionId)
    }
}
