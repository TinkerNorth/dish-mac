// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// S7 on its own rig and loopback Moonlight host, the session up for every
/// rep: pad A's frames are timed from their publish to the host's decrypt,
/// as the satellite scenarios time theirs, while the host sends its rumble
/// and RGB-LED events into the session's receive path.
@MainActor
final class MoonlightScenarioRun {
    private static let startDelayNs: UInt64 = 20_000_000
    private static let settleNs: UInt64 = 200_000_000

    private let scenario: BenchScenario
    private let options: BenchOptions
    private let timer: TimerCalibration
    private let host: LoopbackMoonlightHost
    private let rig: MoonlightPathRig

    /// The host started and a session brought up on it, with pad A announced.
    static func connect(scenario: BenchScenario, options: BenchOptions, timer: TimerCalibration) async throws -> MoonlightScenarioRun {
        let host = try LoopbackMoonlightHost(capacity: options.arrivalCapacity)
        host.start()
        do {
            let rig = try await MoonlightPathRig.connect(to: host, pads: 1)
            return MoonlightScenarioRun(scenario: scenario, options: options, timer: timer, host: host, rig: rig)
        } catch {
            host.stop()
            throw error
        }
    }

    private init(
        scenario: BenchScenario,
        options: BenchOptions,
        timer: TimerCalibration,
        host: LoopbackMoonlightHost,
        rig: MoonlightPathRig
    ) {
        self.scenario = scenario
        self.options = options
        self.timer = timer
        self.host = host
        self.rig = rig
    }

    func run() async -> ScenarioResult {
        let result = await runReps(scenario, options: options) { await runRep(secs: $0) }
        rig.close()
        host.stop()
        return result
    }

    private func runRep(secs: Double) async -> RepResult {
        host.clear()
        resetLockCounts()
        let feedbackBefore = rig.feedback
        let durationNs = UInt64(secs * Double(PaceSchedule.nsPerSecond))
        let startNs = benchNow() + Self.startDelayNs
        let group = DispatchGroup()
        var streams = RepStreams()
        startPad(startNs: startNs, durationNs: durationNs, group: group, into: &streams)
        startHostEvents(startNs: startNs, durationNs: durationNs, group: group, into: &streams)
        await allFinished(group)
        try? await Task.sleep(nanoseconds: Self.settleNs)
        let locks = countedLocks()
        let received = host.take()
        let feedbackAfter = rig.feedback
        let feedback = FeedbackResult(
            rumbleSent: streams.rumbleFrames,
            lightbarSent: (streams.rumbleFrames + BenchRates.lightbarEvery - 1) / BenchRates.lightbarEvery,
            rumbleApplied: feedbackAfter.rumble - feedbackBefore.rumble,
            lightbarApplied: feedbackAfter.lightbar - feedbackBefore.lightbar
        )
        return RepResult(
            streams: streams.measured.map { result($0, received) },
            pacing: streams.paced.map { pacingResult($0) },
            feedback: feedback,
            refreshes: 0,
            talliedReports: 0,
            locks: locks.rows,
            nesting: locks.nesting,
            blocking: locks.blocking
        )
    }

    /// Pad A on its own input queue, its 16-bit sequence in the right stick's X.
    private func startPad(startNs: UInt64, durationNs: UInt64, group: DispatchGroup, into streams: inout RepStreams) {
        let pacer = makePacer(rateHz: options.rateHz, startNs: startNs, durationNs: durationNs, role: nil, timer: timer)
        let published = StampLog(capacity: pacer.frames)
        let rig = rig
        let queue = rig.inputQueues[0]
        group.enter()
        pacer.start(
            emit: { frame in
                queue.async {
                    published.record(frame, benchNow())
                    rig.publish(pad: 0, report: GamepadReport(rx: Int16(bitPattern: UInt16(truncatingIfNeeded: frame))))
                }
            },
            finish: { queue.async { group.leave() } }
        )
        let measured = MeasuredStream(
            pad: "A",
            source: ThreadRole.input.name,
            rateHz: options.rateHz,
            controllerIndex: Int(rig.padNumbers[0]),
            published: published,
            readsSwitchStick: false
        )
        streams.add(PacedStream(name: "A", schedule: pacer.schedule, issued: pacer.issued), measuring: measured)
    }

    /// The host's rumble at 100 a second, an RGB-LED event with every tenth.
    private func startHostEvents(startNs: UInt64, durationNs: UInt64, group: DispatchGroup, into streams: inout RepStreams) {
        let pacer = makePacer(rateHz: BenchRates.rumbleHz, startNs: startNs, durationNs: durationNs, role: nil, timer: timer)
        let host = host
        let number = rig.padNumbers[0]
        group.enter()
        pacer.start(
            emit: { tick in
                host.sendRumble(controller: number, low: 40000, high: 20000)
                if tick % BenchRates.lightbarEvery == 0 {
                    host.sendRgbLed(controller: number, red: 255, green: 0, blue: 128)
                }
            },
            finish: { group.leave() }
        )
        streams.rumbleFrames = pacer.frames
        streams.add(PacedStream(name: "rumble", schedule: pacer.schedule, issued: pacer.issued))
    }

    /// Every input packet naming the pad counts as one of its datagrams; its
    /// CONTROLLER_MULTI frames are the ones timed.
    private func result(_ stream: MeasuredStream, _ received: [LoopbackMoonlightHost.Received]) -> StreamResult {
        let named = received.filter { $0.inputType != nil && $0.controller.map(Int.init) == stream.controllerIndex }
        let frames = named
            .filter { $0.inputType == MoonlightInputType.controllerMulti }
            .map { StreamArrival(sequence: UInt16(bitPattern: $0.rightX), ns: $0.ns) }
        let summary = StreamLatency(sentNs: stream.published.values, arrivals: frames)
        return StreamResult(summary, pad: stream.pad, source: stream.source, rateHz: stream.rateHz, datagrams: named.count)
    }
}
