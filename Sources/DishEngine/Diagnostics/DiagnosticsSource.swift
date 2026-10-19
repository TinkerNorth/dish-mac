// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

package struct HostDiagnostics: Equatable, Identifiable {
    package let summary: ConnectionSummary
    /// The satellite session; resting for a host of any other kind.
    package let facts: HostSessionFacts
    /// The Moonlight session; nil for a satellite.
    package let moonlight: MoonlightHostDiagnostics?

    package var id: String {
        summary.id
    }

    package init(summary: ConnectionSummary, facts: HostSessionFacts, moonlight: MoonlightHostDiagnostics? = nil) {
        self.summary = summary
        self.facts = facts
        self.moonlight = moonlight
    }
}

/// A pad's own audio as the pipeline sees it: its route, the engine's
/// plan and lamp once bound, and the lanes' counters.
package struct PadAudioDiagnostics: Equatable {
    package let route: PadAudioRoute?
    package let state: ControllerAudioState?
    package let counters: AudioCounters?

    package init(route: PadAudioRoute?, state: ControllerAudioState?, counters: AudioCounters?) {
        self.route = route
        self.state = state
        self.counters = counters
    }
}

package struct PadDiagnostics: Equatable, Identifiable {
    package let slot: ControllerSlot
    /// Nil for an unbound pad, or one whose connection carries no descriptor.
    package let wire: SlotWireFacts?
    /// Nil until the audio catalog has been read.
    package let audio: PadAudioDiagnostics?

    package var id: String {
        slot.id
    }

    package init(slot: ControllerSlot, wire: SlotWireFacts?, audio: PadAudioDiagnostics? = nil) {
        self.slot = slot
        self.wire = wire
        self.audio = audio
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
    private let moonlight: MoonlightConnectionManager?
    private var slots: () -> [ControllerSlot] = { [] }
    private var audio: (String) -> PadAudioDiagnostics? = { _ in nil }
    private var timer: DispatchSourceTimer?

    init(wifi: WifiConnectionManager, hub: ConnectionHub, moonlight: MoonlightConnectionManager? = nil) {
        self.wifi = wifi
        self.hub = hub
        self.moonlight = moonlight
        super.init(initial: DiagnosticsSnapshot())
    }

    /// The slot list to read, set once the owner has one.
    func useSlots(_ provider: @escaping () -> [ControllerSlot]) {
        slots = provider
    }

    /// Each pad's audio by slot id, set once the owner has a pipeline.
    func useAudio(_ provider: @escaping (String) -> PadAudioDiagnostics?) {
        audio = provider
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
                facts: wifi.get(summary.id).map(hostSessionFacts) ?? HostSessionFacts.resting(id: summary.id),
                moonlight: moonlightFacts(summary)
            )
        }
        let pads = slots().map { slot in
            PadDiagnostics(slot: slot, wire: slot.boundConnectionId.flatMap { wifi.get($0) }.flatMap(slotWireFacts), audio: audio(slot.id))
        }
        return DiagnosticsSnapshot(hosts: hosts, pads: pads)
    }

    /// A Moonlight host's session, read off its connection when one exists
    /// this run and resting on what its probe said when none does.
    private func moonlightFacts(_ summary: ConnectionSummary) -> MoonlightHostDiagnostics? {
        guard summary.kind == .moonlight, let moonlight else { return nil }
        let info = moonlight.hostFacts[summary.id]
        guard let connection = moonlight.get(summary.id) else { return .resting(info: info) }
        return .read(connection, info: info)
    }
}
