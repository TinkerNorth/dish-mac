// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A scenario: what runs beside the pad whose reports are timed.
struct BenchScenario: Equatable {
    let name: String
    let summary: String
    /// A second pad at 250 Hz on the same input queue.
    let padB: Bool
    /// The main actor refreshing the routing table and reading the tally.
    let mainRole: Bool
    /// Rumble and light-bar commands from the satellite into the receive path.
    let feedback: Bool
    /// The 2 s heartbeat and microphone packets from the capture queue.
    let heartbeatAndMic: Bool
    /// A Direct Switch Pro pad on the reader's thread instead of the input queue.
    let direct: Bool
    /// Pad A bound to a Moonlight host instead of a satellite.
    let moonlight: Bool

    /// Whether the lock gate holds the scenario's hot roles to no lock. The
    /// Moonlight path's send still takes its session's lock for the ENet
    /// bookkeeping, so its locks are pinned by its own lock laws instead.
    var lockGated: Bool {
        !moonlight
    }

    /// The pads it publishes through the input queue.
    var inputPads: Int {
        if direct { return 0 }
        return padB ? 2 : 1
    }
}

/// The rates the scenarios run their other streams at.
enum BenchRates {
    static let padBHz = 250
    static let directHz = 1000
    static let rumbleHz = 100
    /// One light-bar command with every tenth rumble: ten a second.
    static let lightbarEvery = 10
    static let refreshNs: UInt64 = 100_000_000
    static let tallyNs: UInt64 = 1_000_000_000
}

/// S1 to S5 build on each other; S6 is the Direct path on its own, S7 the Moonlight path.
let benchScenarios = [
    BenchScenario(
        name: "S1",
        summary: "pad A on the input queue",
        padB: false,
        mainRole: false,
        feedback: false,
        heartbeatAndMic: false,
        direct: false,
        moonlight: false
    ),
    BenchScenario(
        name: "S2",
        summary: "S1 and pad B at 250 Hz on the same queue",
        padB: true,
        mainRole: false,
        feedback: false,
        heartbeatAndMic: false,
        direct: false,
        moonlight: false
    ),
    BenchScenario(
        name: "S3",
        summary: "S2 and the main actor refreshing the routing table every 100 ms and reading the tally every second",
        padB: true,
        mainRole: true,
        feedback: false,
        heartbeatAndMic: false,
        direct: false,
        moonlight: false
    ),
    BenchScenario(
        name: "S4",
        summary: "S3 and the satellite sending 100 rumble and 10 light-bar commands a second into the receive path",
        padB: true,
        mainRole: true,
        feedback: true,
        heartbeatAndMic: false,
        direct: false,
        moonlight: false
    ),
    BenchScenario(
        name: "S5",
        summary: "S4 and the 2 s heartbeat and microphone packets at --mic-hz",
        padB: true,
        mainRole: true,
        feedback: true,
        heartbeatAndMic: true,
        direct: false,
        moonlight: false
    ),
    BenchScenario(
        name: "S6",
        summary: "a Direct Switch Pro pad at 1000 Hz on the reader's thread, input and motion in every report",
        padB: false,
        mainRole: false,
        feedback: false,
        heartbeatAndMic: false,
        direct: true,
        moonlight: false
    ),
    BenchScenario(
        name: "S7",
        summary: "pad A bound to a Moonlight host on the loopback at --rate, the host sending 100 rumble and 10 RGB-LED events a second",
        padB: false,
        mainRole: false,
        feedback: true,
        heartbeatAndMic: false,
        direct: false,
        moonlight: true
    )
]
