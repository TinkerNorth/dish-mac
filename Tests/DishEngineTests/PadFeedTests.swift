// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import XCTest
@testable import DishEngine

/// A pad's feed: its record packs every value bit for bit, the main actor
/// never reads a record half written, and a route posted while the pad
/// sends reaches it.
final class PadFeedTests: XCTestCase {

    func testEveryRecordedValueReadsBackBitForBit() {
        let reports = [
            GamepadReport(buttons: 0xFFFF, lt: 255, rt: 0, lx: .min, ly: .max, rx: -1, ry: 0),
            GamepadReport(buttons: 0x8001, lt: 1, rt: 254, lx: 1, ly: -1, rx: .max, ry: .min),
            .released
        ]
        for report in reports {
            XCTAssertEqual(GamepadReport(packedLow: report.packedLow, high: report.packedHigh), report)
        }
        let motion = MotionSample(gyroX: .min, gyroY: .max, gyroZ: -1, accelX: 1, accelY: -32000, accelZ: 32000)
        XCTAssertEqual(MotionSample(packedLow: motion.packedLow, high: motion.packedHigh), motion)
        let touch = TouchpadSample(
            finger0: TouchpadFinger(active: true, id: 255, x: .min, y: .max),
            finger1: TouchpadFinger(active: false, id: 1, x: -1, y: 1),
            buttonPressed: true
        )
        XCTAssertEqual(TouchpadSample(packedLow: touch.packedLow, high: touch.packedHigh), touch)
        let zones = GamepadInputProcessor.Deadzones(stickFlat: -5, triggerFlat: 255)
        XCTAssertEqual(GamepadInputProcessor.Deadzones(packed: zones.packed), zones)
    }

    /// The pad's thread writes reports whose fields all carry one number;
    /// the main actor reads the record meanwhile. A read that mixed two
    /// writes would hold two numbers.
    func testTheMainActorNeverReadsARecordHalfWritten() {
        let processor = GamepadInputProcessor()
        let feed = processor.feed(for: "pad")
        let done = DispatchSemaphore(value: 0)
        let writes = 20000
        Thread {
            for step in 1 ... writes {
                let value = Int16(truncatingIfNeeded: step)
                feed.publish(GamepadReport(buttons: UInt16(bitPattern: value), lx: value, ly: value, rx: value, ry: value))
            }
            done.signal()
        }.start()
        var reads = 0
        while done.wait(timeout: .now()) == .timedOut {
            guard let input = processor.latestInput("pad"), let raw = input.raw else { continue }
            reads += 1
            XCTAssertEqual(Set([raw.lx, raw.ly, raw.rx, raw.ry, Int16(bitPattern: raw.buttons)]).count, 1, "one write's fields")
            XCTAssertEqual(input.filtered, raw, "no dead zone, so the host's view is the pad's")
        }
        XCTAssertGreaterThan(reads, 0)
        XCTAssertEqual(processor.latestInput("pad")?.reports, UInt64(writes))
    }

    /// A route posted from the main actor while another thread publishes
    /// reaches that thread with one of its next reports.
    func testARoutePostedWhileThePadSendsReachesIt() {
        let processor = GamepadInputProcessor()
        let feed = processor.feed(for: "pad")
        let recorder = InputRecorder()
        let stop = AtomicBool(false)
        let stopped = DispatchSemaphore(value: 0)
        Thread {
            while !stop.get() {
                feed.publish(GamepadReport(buttons: 1))
            }
            stopped.signal()
        }.start()
        processor.route(recorder.route)
        let deadline = Date().addingTimeInterval(5)
        while recorder.reports.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        stop.set(true)
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(recorder.reports.isEmpty, "the sending thread took the route")
    }
}

/// A satellite pad's route holds its connection's live client, resolved on
/// the main actor.
@MainActor
final class PadRouteResolutionTests: XCTestCase {

    /// A satellite pad's route holds its connection's live client, and the
    /// connection says when that client comes and goes.
    func testASatellitePadsRouteHoldsTheLiveClientAndFollowsIt() throws {
        let server = DiscoveredServer(name: "Sat", ip: "127.0.0.1", udpPort: 9, machineId: "sat")
        let conn = WifiConnection(id: server.id, server: server)
        _ = try XCTUnwrap(conn.attachSlot("pad", controllerType: 0, capabilities: .none))
        var changes = 0
        conn.onClientChanged = { changes += 1 }
        let snapshot = routeSnapshot(bindings: ["pad": conn.id], pool: [conn.id: conn], flags: [:], global: ForwardingFlags())
        XCTAssertNil(resolvedRoutes(snapshot)["pad"], "no client, no route")

        let client = SatelliteClient()
        XCTAssertTrue(client.setConnectionParams(host: "127.0.0.1", udpPort: 9, token: 1, sessionKey: DataPlaneTestHelpers.testKey))
        conn.markConnecting()
        conn.markConnected(client: client, connectionId: "c", epoch: 0, hooks: SessionHooks())
        let sink = try XCTUnwrap(resolvedRoutes(snapshot)["pad"]?.sink as? SatelliteClientSink)
        XCTAssertTrue(sink.client === client)
        XCTAssertEqual(sink.controllerIndex, conn.controllerIndex(of: "pad"))

        conn.markDisconnected()
        XCTAssertNil(resolvedRoutes(snapshot)["pad"], "the client went with the session")
        XCTAssertEqual(changes, 2, "one change as it came, one as it went")
    }
}
