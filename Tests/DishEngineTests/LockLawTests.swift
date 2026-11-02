// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import XCTest
@testable import DishEngine

/// The locks each hot thread takes, read off the production objects running
/// in their roles: a pad publishing reports, motion and touches on the input
/// queue, a Direct Switch Pro pad on the reader's thread, the client's
/// receive loop opening rumble, light-bar and heartbeat-ack datagrams from a
/// loopback satellite, the heartbeat, and the main actor refreshing the
/// routing table every 100 ms; and on a run of its own, a pad bound to a
/// Moonlight host on the loopback, whose control socket's queue opens the
/// host's rumble and RGB-LED events. The lists are a ratchet: a lock that
/// appears fails, and so does a listed one no longer observed until it is
/// deleted. The satellite path's lists are empty: its hot threads take no lock.
@MainActor
final class LockLawTests: XCTestCase {

    #if LOCK_STATS
    func testEachHotThreadTakesExactlyTheLocksOnItsList() throws {
        let run = try runTheHotPaths()
        XCTAssertGreaterThan(run.inputArrivals, 0, "the pad's reports reached the satellite")
        XCTAssertGreaterThan(run.directArrivals, 0, "the Direct pad's reports reached the satellite")
        XCTAssertGreaterThan(run.feedback.rumble, 0, "rumble reached the actuators")
        XCTAssertGreaterThan(run.feedback.lightbar, 0, "the light bar reached the actuators")
        XCTAssertGreaterThan(run.tallied, 0, "the main actor read the tally")
        let snapshot = run.snapshot
        expectExactly("Input may acquire", observed: snapshot.acquired(by: .input), listed: LockLaws.inputMayAcquire)
        expectExactly("HidReader may acquire", observed: snapshot.acquired(by: .hidReader), listed: LockLaws.hidReaderMayAcquire)
        expectExactly("Receive may acquire", observed: snapshot.acquired(by: .receive), listed: LockLaws.receiveMayAcquire)
        expectExactly("held across a blocking call", observed: labels(snapshot.blocking.keys), listed: LockLaws.blockingMayHold)
        expectExactly("taken inside another", observed: labels(snapshot.edges.keys), listed: LockLaws.orderMayNest)
        XCTAssertNil(nestingCycle(Array(snapshot.edges.keys)), "the nesting order has a cycle")
    }

    func testEachMoonlightThreadTakesExactlyTheLocksOnItsList() async throws {
        let run = try await runTheMoonlightPath()
        XCTAssertGreaterThan(run.frames, 0, "the pad's frames reached the host")
        XCTAssertGreaterThan(run.feedback.rumble, 0, "the host's rumble reached the actuators")
        XCTAssertGreaterThan(run.feedback.lightbar, 0, "the host's light reached the actuators")
        let snapshot = run.snapshot
        expectExactly(
            "Input may acquire on the Moonlight path",
            observed: snapshot.acquired(by: .input),
            listed: MoonlightLockLaws.inputMayAcquire
        )
        expectExactly(
            "MoonlightUdp may acquire",
            observed: snapshot.acquired(by: .moonlightUdp),
            listed: MoonlightLockLaws.moonlightUdpMayAcquire
        )
        expectExactly(
            "held across a blocking call on the Moonlight path",
            observed: labels(snapshot.blocking.keys),
            listed: MoonlightLockLaws.blockingMayHold
        )
        expectExactly(
            "taken inside another on the Moonlight path",
            observed: labels(snapshot.edges.keys),
            listed: MoonlightLockLaws.orderMayNest
        )
        XCTAssertNil(nestingCycle(Array(snapshot.edges.keys)), "the nesting order has a cycle")
    }

    private struct MoonlightRun {
        let snapshot: LockStatsSnapshot
        let frames: Int
        let feedback: FramePathFeedback
    }

    /// The pad publishes on its queue and the host sends its events from a
    /// thread of its own for as long as the satellite run takes, while the
    /// main actor refreshes the routing; the session's clock ticks on its
    /// own queue.
    private func runTheMoonlightPath() async throws -> MoonlightRun {
        let host = try LoopbackMoonlightHost(capacity: 100_000)
        host.start()
        defer { host.stop() }
        let rig = try await MoonlightPathRig.connect(to: host, pads: 1)
        resetLockStats()
        let group = DispatchGroup()
        let finished = AtomicBool(false)
        startMoonlightProducer(rig, group: group)
        startHostEvents(host, controller: rig.padNumbers[0], group: group)
        group.notify(queue: .global()) { finished.set(true) }
        var tick = 0
        let giveUp = Date().addingTimeInterval(LockLawRun.limitSeconds)
        while tick < LockLawRun.mainTicks || !finished.get(), Date() < giveUp {
            rig.refreshRouting()
            try await Task.sleep(nanoseconds: LockLawRun.mainTickNs)
            tick += 1
        }
        XCTAssertTrue(finished.get(), "the producers finished")
        try await Task.sleep(nanoseconds: LockLawRun.settleNs)
        let snapshot = lockStatsSnapshot()
        let feedback = rig.feedback
        rig.close()
        let number = rig.padNumbers[0]
        let frames = host.take().filter { $0.inputType == MoonlightInputType.controllerMulti && $0.controller == number }
        return MoonlightRun(snapshot: snapshot, frames: frames.count, feedback: feedback)
    }

    private func startMoonlightProducer(_ rig: MoonlightPathRig, group: DispatchGroup) {
        let queue = rig.inputQueues[0]
        group.enter()
        startThread {
            for frame in 0 ..< LockLawRun.frames {
                queue.async { publishMoonlightFrame(frame, on: rig) }
                Thread.sleep(forTimeInterval: LockLawRun.frameSeconds)
            }
            queue.async { group.leave() }
        }
    }

    private func startHostEvents(_ host: LoopbackMoonlightHost, controller: UInt16, group: DispatchGroup) {
        group.enter()
        startThread {
            for tick in 0 ..< LockLawRun.rumbleTicks {
                host.sendRumble(controller: controller, low: 30000, high: 10000)
                if tick % LockLawRun.lightbarEvery == 0 {
                    host.sendRgbLed(controller: controller, red: 0, green: 64, blue: 255)
                }
                Thread.sleep(forTimeInterval: LockLawRun.rumbleSeconds)
            }
            group.leave()
        }
    }

    private struct HotRun {
        let snapshot: LockStatsSnapshot
        let inputArrivals: Int
        let directArrivals: Int
        let feedback: FramePathFeedback
        let tallied: UInt64
    }

    private func runTheHotPaths() throws -> HotRun {
        let satellite = try LoopbackSatellite(capacity: 100_000)
        satellite.start()
        let rig = try FramePathRig(satellitePort: satellite.port, token: satellite.token, key: satellite.key, pads: 1)
        let direct = try rig.addSwitchProLane()
        drainMain()
        resetLockStats()
        let group = DispatchGroup()
        startInputProducer(rig, group: group)
        startDirectReader(direct, group: group)
        startFeedbackSender(satellite, controllerIndex: UInt8(rig.controllerIndices[0]), group: group)
        var tallied: UInt64 = 0
        var tick = 0
        let giveUp = Date().addingTimeInterval(LockLawRun.limitSeconds)
        while tick < LockLawRun.mainTicks || group.wait(timeout: .now()) == .timedOut, Date() < giveUp {
            rig.refreshRouting()
            if tick % LockLawRun.tallyEvery == 0 { tallied = rig.reportsCounted() }
            RunLoop.main.run(until: Date().addingTimeInterval(LockLawRun.mainTickSeconds))
            tick += 1
        }
        XCTAssertEqual(group.wait(timeout: .now()), .success, "the producers finished")
        RunLoop.main.run(until: Date().addingTimeInterval(LockLawRun.settleSeconds))
        let snapshot = lockStatsSnapshot()
        let feedback = rig.feedback
        rig.close()
        let arrivals = satellite.stop()
        return HotRun(
            snapshot: snapshot,
            inputArrivals: inputs(arrivals, controllerIndex: rig.controllerIndices[0]),
            directArrivals: inputs(arrivals, controllerIndex: direct.controllerIndex),
            feedback: feedback,
            tallied: tallied
        )
    }

    private func startInputProducer(_ rig: FramePathRig, group: DispatchGroup) {
        let queue = rig.inputQueues[0]
        group.enter()
        startThread {
            for frame in 0 ..< LockLawRun.frames {
                queue.async { publishFrame(frame, on: rig) }
                Thread.sleep(forTimeInterval: LockLawRun.frameSeconds)
            }
            queue.async { group.leave() }
        }
    }

    private func startDirectReader(_ direct: DirectFeed, group: DispatchGroup) {
        group.enter()
        startThread {
            ThreadRole.hidReader.enterThread()
            for frame in 0 ..< LockLawRun.frames {
                direct.feed(rightStickX: LockLawRun.stickBase + UInt16(frame % 256), rightStickY: LockLawRun.stickBase)
                Thread.sleep(forTimeInterval: LockLawRun.frameSeconds)
            }
            group.leave()
        }
    }

    private func startFeedbackSender(_ satellite: LoopbackSatellite, controllerIndex: UInt8, group: DispatchGroup) {
        group.enter()
        startThread {
            for tick in 0 ..< LockLawRun.rumbleTicks {
                satellite.sendRumble(controllerIndex: controllerIndex, strong: 30000, weak: 10000, durationMs: 100)
                if tick % LockLawRun.lightbarEvery == 0 {
                    satellite.sendLightbar(controllerIndex: controllerIndex, red: 0, green: 64, blue: 255)
                }
                Thread.sleep(forTimeInterval: LockLawRun.rumbleSeconds)
            }
            group.leave()
        }
    }

    private func expectExactly(_ law: String, observed: Set<String>, listed: [String: Allowance]) {
        let unlisted = observed.subtracting(listed.keys).sorted()
        let stale = Set(listed.keys).subtracting(observed).sorted()
        for name in unlisted {
            XCTFail("\(law): \(name) is not on the list")
        }
        for name in stale {
            XCTFail("\(law): \(name) (\(listed[name]?.rawValue ?? "")) is listed but no longer observed; delete it")
        }
        if !unlisted.isEmpty || !stale.isEmpty {
            print("\(law), observed: \(observed.sorted())")
        }
    }
    #else
    func testTheLawsNeedTheLockStatsBuild() throws {
        throw XCTSkip("built without LOCK_STATS; run swift test -Xswiftc -DLOCK_STATS")
    }
    #endif
}

#if LOCK_STATS
/// Why a lock may be taken on a hot thread: by design, or as debt the hot
/// path still owes.
private enum Allowance: String {
    case byDesign = "by design"
    case debt
}

/// Today's locks per hot thread, exactly. Pairs read `first > second`: an
/// outer lock and one taken inside it, or a blocking call and a lock held
/// across it.
private enum LockLaws {
    static let inputMayAcquire: [String: Allowance] = [:]

    static let hidReaderMayAcquire: [String: Allowance] = [:]

    static let receiveMayAcquire: [String: Allowance] = [:]

    static let blockingMayHold: [String: Allowance] = [:]

    static let orderMayNest: [String: Allowance] = [:]
}

/// Today's locks on the Moonlight path, exactly, from its own run.
private enum MoonlightLockLaws {
    static let inputMayAcquire: [String: Allowance] = [
        "moonlight.padLink": .debt,
        "moonlight.session": .debt,
        "moonlight.transport": .debt
    ]

    static let moonlightUdpMayAcquire: [String: Allowance] = [
        "forwarding.gate": .debt,
        "moonlight.feedbackHandler": .debt,
        "moonlight.padLink": .debt,
        "moonlight.rumbleMixes": .debt,
        "moonlight.session": .debt,
        "moonlight.transport": .debt,
        "routing.table": .debt
    ]

    static let blockingMayHold: [String: Allowance] = [:]

    static let orderMayNest: [String: Allowance] = [:]
}

/// The run's shape: at least two and a half seconds, so the heartbeat's
/// second beat and its ack land inside it, and as long as the producers'
/// sleeps take on a coarse runner timer.
private enum LockLawRun {
    static let limitSeconds: TimeInterval = 60
    static let frames = 2000
    static let frameSeconds = 0.001
    static let mainTicks = 25
    static let mainTickSeconds = 0.1
    static let mainTickNs: UInt64 = 100_000_000
    static let tallyEvery = 10
    static let rumbleTicks = 220
    static let rumbleSeconds = 0.01
    static let lightbarEvery = 10
    static let settleSeconds = 0.3
    static let settleNs: UInt64 = 300_000_000
    /// A raw Switch stick value just past the dead zone.
    static let stickBase: UInt16 = 2369
}

/// A producer at the input queue's quality of service, as a pad's are.
private func startThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.qualityOfService = .userInteractive
    thread.start()
}

/// One input-queue event as GameController delivers them: a report, and on
/// every fourth a motion sample, on every eighth a touch.
private func publishFrame(_ frame: Int, on rig: FramePathRig) {
    rig.publish(pad: 0, report: GamepadReport(rx: Int16(truncatingIfNeeded: frame)))
    if frame % 4 == 0 {
        rig.publishMotion(pad: 0, sample: MotionSample(gyroX: 10, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 8192))
    }
    if frame % 8 == 0 {
        rig.publishTouchpad(pad: 0, x: 1000, y: -1000)
    }
}

/// The same events on a pad bound to a Moonlight host.
private func publishMoonlightFrame(_ frame: Int, on rig: MoonlightPathRig) {
    rig.publish(pad: 0, report: GamepadReport(rx: Int16(truncatingIfNeeded: frame)))
    if frame % 4 == 0 {
        rig.publishMotion(pad: 0, sample: MotionSample(gyroX: 10, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 8192))
    }
    if frame % 8 == 0 {
        rig.publishTouchpad(pad: 0, x: 1000, y: -1000)
    }
}

private func inputs(_ arrivals: [LoopbackSatellite.Arrival], controllerIndex: Int) -> Int {
    arrivals.filter { $0.msgType == ProtocolConstants.msgInput && Int($0.controllerIndex) == controllerIndex }.count
}

private func labels(_ pairs: some Sequence<LockPair>) -> Set<String> {
    Set(pairs.map { "\($0.first) > \($0.second)" })
}

/// A cycle in the nesting order as the locks along it, or nil.
private func nestingCycle(_ edges: [LockPair]) -> [String]? {
    var next: [String: [String]] = [:]
    for edge in edges {
        next[edge.first, default: []].append(edge.second)
    }
    var visiting: Set<String> = []
    var done: Set<String> = []
    var path: [String] = []
    func visit(_ node: String) -> [String]? {
        visiting.insert(node)
        path.append(node)
        for target in next[node] ?? [] {
            if visiting.contains(target) { return Array(path.drop { $0 != target }) + [target] }
            if !done.contains(target), let found = visit(target) { return found }
        }
        path.removeLast()
        visiting.remove(node)
        done.insert(node)
        return nil
    }
    for node in next.keys.sorted() where !done.contains(node) {
        if let found = visit(node) { return found }
    }
    return nil
}
#endif
