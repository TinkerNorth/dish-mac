// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// A stream the rep paces, with the stamps its pacer wrote as it issued each frame.
struct PacedStream {
    let name: String
    let schedule: PaceSchedule
    let issued: StampLog
}

/// A pad whose reports are timed: when each was published, and how an arrival
/// names its frame.
struct MeasuredStream {
    let pad: String
    let source: String
    let rateHz: Int
    let controllerIndex: Int
    let published: StampLog
    let readsSwitchStick: Bool
}

/// Everything one rep started.
struct RepStreams {
    var paced: [PacedStream] = []
    var measured: [MeasuredStream] = []
    var rumbleFrames = 0

    mutating func add(_ stream: PacedStream, measuring pad: MeasuredStream? = nil) {
        paced.append(stream)
        if let pad { measured.append(pad) }
    }
}

/// What the main actor did during a rep.
struct MainRoleWork {
    var refreshes = 0
    var tallied: UInt64 = 0
}

/// One scenario on its own rig and loopback satellite: a warm-up pass that is
/// thrown away, then the reps.
@MainActor
final class ScenarioRun {
    private static let startDelayNs: UInt64 = 20_000_000
    private static let settleNs: UInt64 = 200_000_000
    private static let micPacketBytes = 80

    private let scenario: BenchScenario
    private let options: BenchOptions
    private let spinNs: UInt64
    private let satellite: LoopbackSatellite
    private let rig: FramePathRig
    private let direct: DirectFeed?
    private let switchSequence = SwitchSequence()
    private let captureQueue = ThreadRole.audioCapture.queue(label: "dish.audio.capture", qos: .userInteractive)

    init(scenario: BenchScenario, options: BenchOptions, spinNs: UInt64) throws {
        let satellite = try LoopbackSatellite(capacity: options.arrivalCapacity)
        let rig = try FramePathRig(satellitePort: satellite.port, token: satellite.token, key: satellite.key, pads: scenario.inputPads)
        if scenario.direct {
            direct = try rig.addSwitchProLane()
        } else {
            direct = nil
        }
        if !scenario.heartbeatAndMic { rig.stopHeartbeat() }
        self.scenario = scenario
        self.options = options
        self.spinNs = spinNs
        self.satellite = satellite
        self.rig = rig
    }

    func run() async -> ScenarioResult {
        if !options.smoke {
            // The warm-up pass is thrown away: it pays for first-use costs.
            _ = await runRep(secs: BenchOptions.warmUpSecs)
        }
        var reps: [RepResult] = []
        for _ in 0 ..< options.effectiveReps {
            await reps.append(runRep(secs: options.effectiveSecs))
        }
        rig.close()
        let figures = reps.map { $0.streams.first?.p999Us ?? 0 }
        return ScenarioResult(name: scenario.name, summary: scenario.summary, reportedRep: medianIndex(figures) ?? 0, reps: reps)
    }

    private func runRep(secs: Double) async -> RepResult {
        satellite.start()
        resetLockCounts()
        let feedbackBefore = rig.feedback
        let durationNs = UInt64(secs * Double(PaceSchedule.nsPerSecond))
        let startNs = benchNow() + Self.startDelayNs
        let group = DispatchGroup()
        let streams = startStreams(startNs: startNs, durationNs: durationNs, group: group)
        let mainWork = await runMainRole(until: startNs + durationNs)
        await allFinished(group)
        try? await Task.sleep(nanoseconds: Self.settleNs)
        let locks = countedLocks()
        let arrivals = satellite.stop()
        let feedbackAfter = rig.feedback
        let feedback = FeedbackResult(
            rumbleSent: streams.rumbleFrames,
            lightbarSent: (streams.rumbleFrames + BenchRates.lightbarEvery - 1) / BenchRates.lightbarEvery,
            rumbleApplied: feedbackAfter.rumble - feedbackBefore.rumble,
            lightbarApplied: feedbackAfter.lightbar - feedbackBefore.lightbar
        )
        return RepResult(
            streams: streams.measured.map { result($0, arrivals) },
            pacing: streams.paced.map { pacingResult($0) },
            feedback: scenario.feedback ? feedback : nil,
            refreshes: mainWork.refreshes,
            talliedReports: mainWork.tallied,
            locks: locks.rows,
            nesting: locks.nesting,
            blocking: locks.blocking
        )
    }

    private func startStreams(startNs: UInt64, durationNs: UInt64, group: DispatchGroup) -> RepStreams {
        var streams = RepStreams()
        if let direct {
            startDirect(direct, startNs: startNs, durationNs: durationNs, group: group, into: &streams)
        }
        for pad in 0 ..< scenario.inputPads {
            startInputPad(pad, startNs: startNs, durationNs: durationNs, group: group, into: &streams)
        }
        if scenario.feedback {
            startFeedback(startNs: startNs, durationNs: durationNs, group: group, into: &streams)
        }
        if scenario.heartbeatAndMic {
            startMic(startNs: startNs, durationNs: durationNs, group: group, into: &streams)
        }
        return streams
    }

    /// A pad on the input queue, its 16-bit sequence in the right stick's X.
    private func startInputPad(_ pad: Int, startNs: UInt64, durationNs: UInt64, group: DispatchGroup, into streams: inout RepStreams) {
        let rateHz = pad == 0 ? options.rateHz : BenchRates.padBHz
        let pacer = makePacer(rateHz: rateHz, startNs: startNs, durationNs: durationNs, role: nil)
        let published = StampLog(capacity: pacer.frames)
        let rig = rig
        let queue = rig.inputQueue
        group.enter()
        pacer.start(
            emit: { frame in
                queue.async {
                    published.record(frame, benchNow())
                    rig.publish(pad: pad, report: GamepadReport(rx: Int16(bitPattern: UInt16(truncatingIfNeeded: frame))))
                }
            },
            finish: { queue.async { group.leave() } }
        )
        let name = pad == 0 ? "A" : "B"
        let measured = MeasuredStream(
            pad: name,
            source: ThreadRole.input.name,
            rateHz: rateHz,
            controllerIndex: rig.controllerIndices[pad],
            published: published,
            readsSwitchStick: false
        )
        streams.add(PacedStream(name: name, schedule: pacer.schedule, issued: pacer.issued), measuring: measured)
    }

    /// The Direct pad on a HidReader thread, its sequence on the right stick.
    private func startDirect(
        _ direct: DirectFeed,
        startNs: UInt64,
        durationNs: UInt64,
        group: DispatchGroup,
        into streams: inout RepStreams
    ) {
        let pacer = makePacer(rateHz: BenchRates.directHz, startNs: startNs, durationNs: durationNs, role: .hidReader)
        let published = StampLog(capacity: pacer.frames)
        group.enter()
        pacer.start(
            emit: { frame in
                let stick = SwitchSequence.rawStick(UInt16(truncatingIfNeeded: frame))
                published.record(frame, benchNow())
                direct.feed(rightStickX: stick.x, rightStickY: stick.y)
            },
            finish: { group.leave() }
        )
        let measured = MeasuredStream(
            pad: "A",
            source: ThreadRole.hidReader.name,
            rateHz: BenchRates.directHz,
            controllerIndex: direct.controllerIndex,
            published: published,
            readsSwitchStick: true
        )
        streams.add(PacedStream(name: "Direct", schedule: pacer.schedule, issued: pacer.issued), measuring: measured)
    }

    /// The satellite's rumble at 100 a second, a light-bar command with every tenth.
    private func startFeedback(startNs: UInt64, durationNs: UInt64, group: DispatchGroup, into streams: inout RepStreams) {
        let pacer = makePacer(rateHz: BenchRates.rumbleHz, startNs: startNs, durationNs: durationNs, role: nil)
        let satellite = satellite
        let index = UInt8(truncatingIfNeeded: rig.controllerIndices.first ?? 0)
        group.enter()
        pacer.start(
            emit: { tick in
                satellite.sendRumble(controllerIndex: index, strong: 40000, weak: 20000, durationMs: 100)
                if tick % BenchRates.lightbarEvery == 0 {
                    satellite.sendLightbar(controllerIndex: index, red: 255, green: 0, blue: 128)
                }
            },
            finish: { group.leave() }
        )
        streams.rumbleFrames = pacer.frames
        streams.add(PacedStream(name: "rumble", schedule: pacer.schedule, issued: pacer.issued))
    }

    /// Microphone packets handed to the connection from the capture queue.
    private func startMic(startNs: UInt64, durationNs: UInt64, group: DispatchGroup, into streams: inout RepStreams) {
        let pacer = makePacer(rateHz: options.micHz, startNs: startNs, durationNs: durationNs, role: nil)
        let rig = rig
        let queue = captureQueue
        let packet = Data(repeating: 0x5A, count: Self.micPacketBytes)
        group.enter()
        pacer.start(
            emit: { _ in queue.async { rig.sendMic(pad: 0, opus: packet) } },
            finish: { queue.async { group.leave() } }
        )
        streams.add(PacedStream(name: "mic", schedule: pacer.schedule, issued: pacer.issued))
    }

    private func makePacer(rateHz: Int, startNs: UInt64, durationNs: UInt64, role: ThreadRole?) -> Pacer {
        let schedule = PaceSchedule(startNs: startNs, rateHz: UInt64(rateHz))
        let frames = Int(schedule.frames(within: durationNs))
        return Pacer(schedule: schedule, frames: frames, spinNs: spinNs, role: role, issued: StampLog(capacity: frames))
    }

    /// The main actor's share: the routing refresh every 100 ms and the tally
    /// every second in S3 and later, idle otherwise so its hops land.
    private func runMainRole(until endNs: UInt64) async -> MainRoleWork {
        var work = MainRoleWork()
        var nextTallyNs = benchNow()
        while benchNow() < endNs {
            if scenario.mainRole {
                rig.refreshRouting()
                work.refreshes += 1
                if benchNow() >= nextTallyNs {
                    work.tallied = rig.reportsCounted()
                    nextTallyNs += BenchRates.tallyNs
                }
            }
            let now = benchNow()
            let left = endNs > now ? endNs - now : 0
            try? await Task.sleep(nanoseconds: min(BenchRates.refreshNs, left))
        }
        return work
    }

    private func result(_ stream: MeasuredStream, _ arrivals: [LoopbackSatellite.Arrival]) -> StreamResult {
        let named = arrivals.filter { Int($0.controllerIndex) == stream.controllerIndex }
        let inputs = named.filter { $0.msgType == ProtocolConstants.msgInput }.compactMap { streamArrival($0, of: stream) }
        let summary = StreamLatency(sentNs: stream.published.values, arrivals: inputs)
        return StreamResult(summary, pad: stream.pad, source: stream.source, rateHz: stream.rateHz, datagrams: named.count)
    }

    private func streamArrival(_ arrival: LoopbackSatellite.Arrival, of stream: MeasuredStream) -> StreamArrival? {
        let sequence: UInt16? = stream.readsSwitchStick
            ? switchSequence.sequence(rx: arrival.rx, ry: arrival.ry)
            : UInt16(bitPattern: arrival.rx)
        return sequence.map { StreamArrival(sequence: $0, ns: arrival.ns) }
    }
}

func pacingResult(_ stream: PacedStream) -> PacingResult {
    let stamps = stream.issued.values
    let check = PacingCheck(stampsNs: stamps, schedule: stream.schedule)
    return PacingResult(check, stream: stream.name, rateHz: Int(stream.schedule.rateHz), frames: stamps.count)
}

/// Resumes when every stream the group counts has finished.
func allFinished(_ group: DispatchGroup) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) { continuation.resume() }
    }
}
