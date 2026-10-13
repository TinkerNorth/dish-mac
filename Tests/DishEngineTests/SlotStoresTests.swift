// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishEngine

/// The two per-binding stores: a pick and a motion word keyed by satellite
/// and pad, cleared one binding or one satellite at a time, and silent on a
/// change that changes nothing.
@MainActor
final class SlotStoresTests: XCTestCase {

    private let desk = SlotKey(connectionId: "desk", slotId: "pad-1")
    private let deskTwo = SlotKey(connectionId: "desk", slotId: "pad-2")
    private let den = SlotKey(connectionId: "den", slotId: "pad-1")
    private var bag = Set<AnyCancellable>()

    // MARK: - Picks

    func testAPickIsReadBackAndClearedPerBinding() {
        let store = ControllerTypeStore()
        XCTAssertNil(store.typeFor(desk))
        store.setType(2, for: desk)
        store.setType(1, for: den)
        XCTAssertEqual(store.typeFor(desk), 2)
        XCTAssertEqual(store.typeFor(den), 1)
        store.clear(desk)
        XCTAssertNil(store.typeFor(desk))
        XCTAssertEqual(store.typeFor(den), 1, "the other satellite's pick survives")
    }

    func testForgettingASatelliteDropsEveryPickUnderIt() {
        let store = ControllerTypeStore()
        store.setType(2, for: desk)
        store.setType(3, for: deskTwo)
        store.setType(1, for: den)
        store.clearConnection("desk")
        XCTAssertEqual(store.state, [den: 1])
    }

    func testClearingAnAbsentPickEmitsNothing() {
        let store = ControllerTypeStore()
        var emissions = 0
        store.statePublisher.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        store.clear(desk)
        store.clearConnection("desk")
        XCTAssertEqual(emissions, 0)
        store.setType(2, for: desk)
        store.setType(2, for: desk)
        XCTAssertEqual(emissions, 1, "the same pick twice is one change")
    }

    // MARK: - Motion words

    func testAMotionWordIsReadBackAndClearedPerBinding() {
        let store = MotionBackendStatusStore()
        let good = MotionBackendStatus(sinkSupportedForType: true, backendOk: true)
        let noSink = MotionBackendStatus(sinkSupportedForType: false, backendOk: true)
        store.setStatus(good, for: desk)
        store.setStatus(noSink, for: den)
        XCTAssertEqual(store.statusFor(desk), good)
        XCTAssertEqual(store.statusFor(den), noSink)
        XCTAssertTrue(good.effective)
        XCTAssertFalse(noSink.effective)
        store.clear(desk)
        XCTAssertNil(store.statusFor(desk))
        store.clearConnection("den")
        XCTAssertEqual(store.state, [:])
    }
}
