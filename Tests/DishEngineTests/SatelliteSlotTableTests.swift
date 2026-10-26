// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// A satellite connection's pads as pure state: each holds the lowest free
/// controller index for as long as it stays bound, its descriptor reads its
/// own switches over the connection's, only what the satellite confirmed
/// counts toward the ack's bitmap, and the indices an edit changed are the
/// ones that converge.
final class SatelliteSlotTableTests: XCTestCase {

    private let motion = ControllerCapabilities(hasMotion: true)
    private let touchpad = ControllerCapabilities(hasTouchpad: true)

    private func table(_ slotIds: [String], capabilities: ControllerCapabilities = .none) -> SatelliteSlotTable {
        var table = SatelliteSlotTable()
        for slotId in slotIds {
            table.attach(slotId, controllerType: 0, capabilities: capabilities, family: .other)
        }
        return table
    }

    func testAttachingHandsOutTheLowestFreeIndexAndRefusesAFifth() {
        var table = table(["a", "b", "c", "d"])
        XCTAssertEqual(table.boundSlotIds, ["a", "b", "c", "d"])
        XCTAssertFalse(table.hasRoom)
        XCTAssertNil(table.attach("e", controllerType: 0, capabilities: .none, family: .other))
        XCTAssertEqual(table.detach("b"), 1)
        XCTAssertNil(table.detach("b"), "nothing left to let go")
        XCTAssertEqual(table.attach("e", controllerType: 0, capabilities: .none, family: .other), 1)
        XCTAssertEqual(table.slotId(at: 1), "e")
    }

    func testAttachingABoundSlotAgainKeepsItsIndexAndTakesTheNewFacts() {
        var table = table(["a", "b"])
        XCTAssertEqual(table.attach("b", controllerType: 2, capabilities: motion, family: .dualSense), 1)
        XCTAssertEqual(table.slots["b"]?.controllerType, 2)
        XCTAssertEqual(table.slots["b"]?.family, .dualSense)
        XCTAssertEqual(table.descriptor(for: "b")?.caps, ProtocolConstants.capAnalogTriggers | ProtocolConstants.capMotion)
    }

    func testEachDescriptorReadsItsOwnSwitchesOverTheConnections() {
        var table = table(["a", "b"], capabilities: motion)
        table.connectionFlags = ForwardingFlags(motion: true)
        table.slotFlags = ["a": ForwardingFlags(motion: false)]
        let byIndex = table.descriptorsByIndex()
        XCTAssertEqual(byIndex[0]?.caps, ProtocolConstants.capAnalogTriggers, "slot a switched its motion off")
        XCTAssertEqual(byIndex[1]?.caps, ProtocolConstants.capAnalogTriggers | ProtocolConstants.capMotion, "slot b reads the connection's")
        XCTAssertEqual(table.descriptors.map(\.ctrlIdx), [0, 1], "a session PUT carries them in index order")
    }

    func testOnlyConfirmedPadsCountTowardTheBitmapAndASessionEndUnconfirmsThem() {
        var table = table(["a", "b"])
        XCTAssertTrue(table.markApplied("b"))
        XCTAssertFalse(table.markApplied("zz"), "a slot that is not bound is not counted")
        XCTAssertEqual(table.appliedSlots(), [DesiredSlot(ctrlIdx: 1, type: 0)])
        XCTAssertEqual(table.unappliedIndices, [0])
        table.clearApplied()
        XCTAssertEqual(table.appliedSlots(), [])
        XCTAssertEqual(table.unappliedIndices, [0, 1])
        XCTAssertEqual(table.applyCount(of: "b"), 1, "the count survives the session")
    }

    func testTheSessionAsksForTheMouseWhenAnyPadPicksIt() {
        var table = table(["a", "b"], capabilities: touchpad)
        XCTAssertFalse(table.wantsMouseControl)
        table.slotFlags = ["b": ForwardingFlags(touchpadPick: .mouse)]
        XCTAssertTrue(table.wantsMouseControl)
        table.slotFlags = ["b": ForwardingFlags(touchpad: false, touchpadPick: .mouse)]
        XCTAssertFalse(table.wantsMouseControl, "a touchpad switched off asks for nothing")
    }

    func testTheIndicesThatConvergeAreTheOnesThatAppearedWentOrChanged() {
        var table = table(["a", "b", "c"])
        let before = table.descriptorsByIndex()
        table.detach("a")
        table.setControllerType(3, for: "b")
        XCTAssertEqual(changedIndices(before, table.descriptorsByIndex()), [0, 1], "c is untouched")
        XCTAssertEqual(changedIndices(before, before), [])
    }
}
