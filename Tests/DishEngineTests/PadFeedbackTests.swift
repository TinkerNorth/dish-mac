// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import XCTest
@testable import DishEngine

/// Feedback in one hop: the receive loop resolves each command against the
/// routes its handlers captured and posts it to the pad's record, and the
/// feedback queue applies the newest of each kind. The decisions are the
/// router's old ones, a burst drains once, and the main thread is not on
/// the way.
@MainActor
final class PadFeedbackTests: XCTestCase {

    private enum Kind: CaseIterable {
        case rumble, lightbar, triggerEffects, playerLeds
    }

    // MARK: - Routing decisions

    /// Pads on two satellites, one with its rumble switched off.
    private var snapshot: RoutingSnapshot {
        var snapshot = RoutingSnapshot()
        let quiet = ForwardingFlags(rumble: false)
        snapshot.bySatellitePad[SatellitePadKey(connectionId: "sat-a", controllerIndex: 0)] = BoundSlotRoute(
            slotId: "a0",
            flags: ForwardingFlags()
        )
        snapshot.bySatellitePad[SatellitePadKey(connectionId: "sat-a", controllerIndex: 1)] = BoundSlotRoute(slotId: "a1", flags: quiet)
        snapshot.bySatellitePad[SatellitePadKey(connectionId: "sat-a", controllerIndex: 3)] = BoundSlotRoute(
            slotId: "a3",
            flags: ForwardingFlags()
        )
        snapshot.bySatellitePad[SatellitePadKey(connectionId: "sat-b", controllerIndex: 0)] = BoundSlotRoute(
            slotId: "b0",
            flags: ForwardingFlags()
        )
        return snapshot
    }

    /// The rule the router applied against the live table before: the slot
    /// bound to the connection's index, behind the controller's Rumble switch
    /// for rumble and the global Light bar switch for the light bar; the two
    /// feedback paths have no switch.
    private func expectedSlot(_ kind: Kind, connection: String, index: UInt8, global: ForwardingFlags) -> String? {
        let key = SatellitePadKey(connectionId: connection, controllerIndex: Int(index))
        guard let bound = snapshot.bySatellitePad[key] else { return nil }
        switch kind {
        case .rumble:
            return ReturnPathRouting.shouldVibrate(flags: bound.flags) ? bound.slotId : nil
        case .lightbar:
            let command = LightbarCommand(controllerIndex: index, r: 1, g: 2, b: 3)
            return ReturnPathRouting.shouldApply(lightbar: command, flags: global) ? bound.slotId : nil
        case .triggerEffects, .playerLeds:
            return bound.slotId
        }
    }

    func testEveryTargetIsDecidedAsTheRouterDecidedIt() {
        for global in [ForwardingFlags(), ForwardingFlags(lightbar: false)] {
            for connection in ["sat-a", "sat-b", "sat-unknown"] {
                for index in [UInt8(0), 1, 2, 3, 9] {
                    for kind in Kind.allCases {
                        let actuated = deliver(kind, connection: connection, index: index, global: global)
                        let expected = expectedSlot(kind, connection: connection, index: index, global: global)
                        XCTAssertEqual(
                            actuated,
                            expected.map { [$0] } ?? [],
                            "\(kind) on \(connection)[\(index)], light bar \(global.lightbar)"
                        )
                    }
                }
            }
        }
    }

    /// One command through the routes a connection's handlers would capture,
    /// and the slots the queue actuated for it.
    private func deliver(_ kind: Kind, connection: String, index: UInt8, global: ForwardingFlags) -> [String] {
        let recorder = FeedbackLog()
        let feedback = PadFeedback(actuators: recorder.actuators)
        let routes = FeedbackRoutes(connectionId: connection, snapshot: snapshot, global: global, feedback: feedback)
        switch kind {
        case .rumble:
            routes.rumble(RumbleCommand(controllerIndex: index, strongMagnitude: 100, weakMagnitude: 200, durationMs: 300))
        case .lightbar:
            routes.lightbar(LightbarCommand(controllerIndex: index, r: 1, g: 2, b: 3))
        case .triggerEffects:
            routes.triggerEffects(TriggerEffectsCommand(controllerIndex: index, left: Self.block, right: Self.block))
        case .playerLeds:
            routes.playerLeds(PlayerLedsCommand(controllerIndex: index, ledMask: 0b0010))
        }
        feedback.queue.sync {}
        return recorder.entries.map(\.slotId)
    }

    private static let block = [UInt8](repeating: 0, count: ProtocolConstants.triggerEffectBlockBytes)

    // MARK: - Coalescing

    func testABurstWhileTheQueueIsBusyAppliesItsLastValueOnce() {
        let recorder = FeedbackLog()
        let feedback = PadFeedback(actuators: recorder.actuators)
        let pad = feedback.pad(for: "pad")
        let release = DispatchSemaphore(value: 0)
        feedback.queue.async { release.wait() }
        for step in 1 ... 50 {
            pad.post(rumble: RumbleCommand(controllerIndex: 0, strongMagnitude: UInt16(step), weakMagnitude: 7, durationMs: 300))
            pad.post(lightbar: LightbarCommand(controllerIndex: 0, r: UInt8(step), g: 0, b: 0))
            pad.post(player: step % 4 + 1)
            pad.post(triggerEffects: TriggerEffectsCommand(
                controllerIndex: 0,
                left: [UInt8(step)] + Self.block.dropFirst(),
                right: Self.block
            ))
        }
        release.signal()
        feedback.queue.sync {}

        XCTAssertEqual(recorder.entries, [
            FeedbackLog.Entry(slotId: "pad", kind: "rumble", value: "50/7/300"),
            FeedbackLog.Entry(slotId: "pad", kind: "lightbar", value: "50/0/0"),
            FeedbackLog.Entry(slotId: "pad", kind: "player", value: "3"),
            FeedbackLog.Entry(slotId: "pad", kind: "triggers", value: "50")
        ])
    }

    func testAPostAfterADrainIsAppliedByTheNextOne() {
        let recorder = FeedbackLog()
        let feedback = PadFeedback(actuators: recorder.actuators)
        let pad = feedback.pad(for: "pad")
        pad.post(rumble: RumbleCommand(controllerIndex: 0, strongMagnitude: 1, weakMagnitude: 0, durationMs: 100))
        feedback.queue.sync {}
        pad.post(rumble: RumbleCommand(controllerIndex: 0, strongMagnitude: 2, weakMagnitude: 0, durationMs: 100))
        feedback.queue.sync {}
        XCTAssertEqual(recorder.entries.map(\.value), ["1/0/100", "2/0/100"])
    }

    func testEachSlotKeepsOneRecord() {
        let feedback = PadFeedback(actuators: FeedbackLog().actuators)
        XCTAssertTrue(feedback.pad(for: "pad") === feedback.pad(for: "pad"))
        XCTAssertFalse(feedback.pad(for: "pad") === feedback.pad(for: "other"))
    }

    // MARK: - No main actor on the way

    /// The main thread waits on the actuator's signal the whole time: if the
    /// rumble needed it, the wait would time out.
    func testARumbleOpenedByTheLoopReachesThePadWhileTheMainThreadWaits() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }
        let arrived = DispatchSemaphore(value: 0)
        let onMain = LockedBox<Bool?>(nil)
        let feedback = PadFeedback(actuators: FeedbackActuators(
            rumble: { _, _, _, _ in
                onMain.set(Thread.isMainThread)
                arrived.signal()
            },
            lightbar: { _, _, _, _ in },
            triggerEffects: { _, _ in },
            playerLeds: { _, _ in }
        ))
        var routing = RoutingSnapshot()
        routing.bySatellitePad[SatellitePadKey(connectionId: "sat", controllerIndex: 0)] = BoundSlotRoute(
            slotId: "pad",
            flags: ForwardingFlags()
        )
        client.onRumble = FeedbackRoutes(connectionId: "sat", snapshot: routing, global: ForwardingFlags(), feedback: feedback).rumble
        client.startReceiveLoop()
        client.sendReport(controllerIndex: 0, report: GamepadReport())
        let clientAddress = try XCTUnwrap(DataPlaneTestHelpers.receiveSender(fd: fd))
        let rumble = DataPlaneTestHelpers.sealDownlink(
            msgType: ProtocolConstants.msgRumble,
            payload: Data([0, 0x75, 0x30, 0x27, 0x10, 0x01, 0xF4]),
            counter: 1
        )
        XCTAssertTrue(DataPlaneTestHelpers.send(rumble, from: fd, to: clientAddress))
        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success, "the rumble reached the pad without the main thread")
        XCTAssertEqual(onMain.get(), false)
    }
}

/// What the feedback queue applied, in order, as text a test can compare.
private final class FeedbackLog {
    struct Entry: Equatable {
        let slotId: String
        let kind: String
        let value: String
    }

    private let log = LockedBox<[Entry]>([])

    var entries: [Entry] {
        log.get()
    }

    var actuators: FeedbackActuators {
        let log = log
        return FeedbackActuators(
            rumble: { slotId, strong, weak, durationMs in
                log.mutate { $0.append(Entry(slotId: slotId, kind: "rumble", value: "\(strong)/\(weak)/\(durationMs)")) }
            },
            lightbar: { slotId, red, green, blue in
                log.mutate { $0.append(Entry(slotId: slotId, kind: "lightbar", value: "\(red)/\(green)/\(blue)")) }
            },
            triggerEffects: { slotId, command in
                log.mutate { $0.append(Entry(slotId: slotId, kind: "triggers", value: "\(command.left.first ?? 0)")) }
            },
            playerLeds: { slotId, player in
                log.mutate { $0.append(Entry(slotId: slotId, kind: "player", value: "\(player)")) }
            }
        )
    }
}
