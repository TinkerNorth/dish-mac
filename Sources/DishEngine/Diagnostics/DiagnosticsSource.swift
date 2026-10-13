// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

package struct HostDiagnostics: Equatable, Identifiable {
    package let summary: ConnectionSummary
    package let facts: HostSessionFacts

    package var id: String {
        summary.id
    }

    package init(summary: ConnectionSummary, facts: HostSessionFacts) {
        self.summary = summary
        self.facts = facts
    }
}

package struct PadDiagnostics: Equatable, Identifiable {
    package let slot: ControllerSlot
    /// Nil for an unbound pad, or one whose connection carries no descriptor.
    package let wire: SlotWireFacts?

    package var id: String {
        slot.id
    }

    package init(slot: ControllerSlot, wire: SlotWireFacts?) {
        self.slot = slot
        self.wire = wire
    }
}

package struct DiagnosticsSnapshot: Equatable {
    package var hosts: [HostDiagnostics] = []
    package var pads: [PadDiagnostics] = []

    package init(hosts: [HostDiagnostics] = [], pads: [PadDiagnostics] = []) {
        self.hosts = hosts
        self.pads = pads
    }
}

/// What the app sees right now, for the Diagnostics window: every figure is
/// one the rest of the app already acts on, not a second measurement. The
/// ack-fed numbers change without a publication, so a 1 Hz tick re-reads
/// them while the window is open; `start` arms it and `stop` ends it.
@MainActor
package final class DiagnosticsSource: StateSource<DiagnosticsSnapshot> {

    private let wifi: WifiConnectionManager
    private let hub: ConnectionHub
    private var slots: () -> [ControllerSlot] = { [] }
    private var timer: DispatchSourceTimer?

    init(wifi: WifiConnectionManager, hub: ConnectionHub) {
        self.wifi = wifi
        self.hub = hub
        super.init(initial: DiagnosticsSnapshot())
    }

    /// The slot list to read, set once the owner has one.
    func useSlots(_ provider: @escaping () -> [ControllerSlot]) {
        slots = provider
    }

    override package func start() {
        MainActor.assumeIsolated {
            refresh()
            arm()
        }
    }

    override package func stop() {
        MainActor.assumeIsolated {
            timer?.cancel()
            timer = nil
        }
    }

    package func refresh() {
        setState(compose())
    }

    private func arm() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.resume()
        timer = source
    }

    private func compose() -> DiagnosticsSnapshot {
        let hosts = hub.connections.map { summary in
            HostDiagnostics(
                summary: summary,
                facts: wifi.get(summary.id).map(hostSessionFacts) ?? HostSessionFacts.resting(id: summary.id)
            )
        }
        let pads = slots().map { slot in
            PadDiagnostics(slot: slot, wire: slot.boundConnectionId.flatMap { wifi.get($0) }.flatMap(slotWireFacts))
        }
        return DiagnosticsSnapshot(hosts: hosts, pads: pads)
    }
}
