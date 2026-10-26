// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The per-pad dead zones under the desktops' keys: a write lands under
/// `deadzone:<slotId>` in their JSON shape and reads back on the next
/// launch, a reset forgets it, a pad never tuned reads the defaults, and a
/// value that does not read is nothing stored.
@MainActor
final class DeadzonePreferenceStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private let tuned = DeadzoneSetting(stickFlat: 6554, triggerFlat: 26)

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAPadNeverTunedReadsTheDefaults() {
        let store = DeadzonePreferenceStore(defaults: defaults)
        XCTAssertEqual(store.zones(for: "pad"), .defaults)
        XCTAssertEqual(store.state, [:])
    }

    func testAWriteLandsUnderTheDesktopsKeyInTheirShape() {
        let store = DeadzonePreferenceStore(defaults: defaults)
        store.setZones(tuned, for: "gc:Sony:DualSense")
        XCTAssertEqual(defaults.string(forKey: "deadzone:gc:Sony:DualSense"), #"{"s":6554,"t":26}"#)
        XCTAssertEqual(store.zones(for: "gc:Sony:DualSense"), tuned)
    }

    func testAWriteReadsBackOnTheNextLaunch() {
        DeadzonePreferenceStore(defaults: defaults).setZones(tuned, for: "pad")
        let relaunched = DeadzonePreferenceStore(defaults: defaults)
        XCTAssertEqual(relaunched.state, ["pad": tuned])
    }

    func testAResetForgetsTheTuningAndReadsTheDefaultsAgain() {
        let store = DeadzonePreferenceStore(defaults: defaults)
        store.setZones(tuned, for: "pad")
        store.reset("pad")
        XCTAssertNil(defaults.object(forKey: "deadzone:pad"))
        XCTAssertEqual(store.zones(for: "pad"), .defaults)
        XCTAssertEqual(DeadzonePreferenceStore(defaults: defaults).state, [:])
    }

    func testAValueThatDoesNotReadIsNothingStored() {
        defaults.set("not json", forKey: "deadzone:pad")
        defaults.set(#"{"s":1000,"t":2}"#, forKey: "deadzone:other")
        XCTAssertEqual(DeadzonePreferenceStore(defaults: defaults).state, ["other": DeadzoneSetting(stickFlat: 1000, triggerFlat: 2)])
    }

    func testARepeatedWriteEmitsOnce() {
        let store = DeadzonePreferenceStore(defaults: defaults)
        var seen: [[String: DeadzoneSetting]] = []
        let bag = store.statePublisher.dropFirst().sink { seen.append($0) }
        store.setZones(tuned, for: "pad")
        store.setZones(tuned, for: "pad")
        bag.cancel()
        XCTAssertEqual(seen, [["pad": tuned]])
    }
}
