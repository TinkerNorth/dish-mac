// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishEngine

/// The per-controller switches: on until written, folded under the global
/// ones, kept in the fleet's JSON shape, and lenient on a garbled blob.
@MainActor
final class SlotPreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - The fold

    func testTheEffectiveSwitchNeedsBothTheGlobalAndTheControllersOwn() {
        let all = ForwardingFlags()
        XCTAssertEqual(effectiveFlags(global: all, slot: SlotPreferences()), all)
        XCTAssertEqual(
            effectiveFlags(global: all, slot: SlotPreferences(motion: false, rumble: false, touchpad: .off)),
            ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: true, touchpadPick: .off)
        )
        XCTAssertEqual(
            effectiveFlags(global: all, slot: SlotPreferences(touchpad: .mouse)),
            ForwardingFlags(touchpadPick: .mouse),
            "the mouse pick sends the touchpad and says what as"
        )
        XCTAssertEqual(
            effectiveFlags(
                global: ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false),
                slot: SlotPreferences()
            ),
            ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false),
            "the global switch outranks a controller's own"
        )
    }

    // MARK: - The store

    func testTheMicIsOffUntilAskedAndTheSpeakerOn() {
        let store = SlotPreferenceStore(defaults: defaults)
        XCTAssertFalse(store.preferences(for: "ds").mic)
        XCTAssertTrue(store.preferences(for: "ds").speaker)
        store.setMic(true, for: "ds")
        store.setSpeaker(false, for: "ds")
        XCTAssertEqual(store.preferences(for: "ds"), SlotPreferences(mic: true, speaker: false))
        XCTAssertNotNil(defaults.string(forKey: SlotPreferenceStore.micKey))
        XCTAssertNotNil(defaults.string(forKey: SlotPreferenceStore.speakerKey))
        XCTAssertEqual(SlotPreferenceStore(defaults: defaults).preferences(for: "ds"), SlotPreferences(mic: true, speaker: false))
        XCTAssertEqual(
            effectiveFlags(global: ForwardingFlags(), slot: SlotPreferences(mic: true, speaker: false)),
            ForwardingFlags(mic: true, speaker: false)
        )
    }

    func testTheTouchpadPickIsWrittenInTheWiresWordsBesideTheOnOffRow() {
        let store = SlotPreferenceStore(defaults: defaults)
        store.setTouchpadPick(.mouse, for: "ds")
        XCTAssertEqual(store.preferences(for: "ds").touchpad, .mouse)
        XCTAssertEqual(defaults.string(forKey: SlotPreferenceStore.touchpadModeKey), #"[{"mode":"mouse","slotId":"ds"}]"#)
        XCTAssertEqual(
            defaults.string(forKey: SlotPreferenceStore.touchpadKey),
            #"[{"enabled":true,"slotId":"ds"}]"#,
            "an older build still reads a switch"
        )
        XCTAssertEqual(SlotPreferenceStore(defaults: defaults).preferences(for: "ds").touchpad, .mouse)
        store.setTouchpad(false, for: "ds")
        XCTAssertEqual(store.preferences(for: "ds").touchpad, .off)
        store.setTouchpad(true, for: "ds")
        XCTAssertEqual(store.preferences(for: "ds").touchpad, .pad, "the chip's click brings the pad render back")
    }

    func testAnOlderOnOffRowReadsAsThePickAndAnUnknownModeIsSkipped() {
        defaults.set(#"[{"enabled":false,"slotId":"ds"},{"enabled":true,"slotId":"xb"}]"#, forKey: SlotPreferenceStore.touchpadKey)
        defaults.set(#"[{"mode":"banana","slotId":"ds"},{"mode":"mouse","slotId":"xb"}]"#, forKey: SlotPreferenceStore.touchpadModeKey)
        let store = SlotPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.preferences(for: "ds").touchpad, .off, "the on/off row speaks when the mode is not a wire word")
        XCTAssertEqual(store.preferences(for: "xb").touchpad, .mouse, "the pick outranks the on/off row")
    }

    func testAControllerNeverSwitchedReadsAllOn() {
        let store = SlotPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.preferences(for: "gc:Sony:DualSense"), SlotPreferences())
        XCTAssertEqual(store.state, [:])
    }

    func testEachSwitchIsWrittenAndReadBackPerController() {
        let store = SlotPreferenceStore(defaults: defaults)
        store.setMotion(false, for: "ds")
        store.setRumble(false, for: "xbox")
        store.setTouchpad(false, for: "ds")
        XCTAssertEqual(store.preferences(for: "ds"), SlotPreferences(motion: false, rumble: true, touchpad: .off))
        XCTAssertEqual(store.preferences(for: "xbox"), SlotPreferences(motion: true, rumble: false, touchpad: .pad))
        let relaunch = SlotPreferenceStore(defaults: defaults)
        XCTAssertEqual(relaunch.state, store.state, "the switches survive a relaunch")
    }

    func testTheRowsAreTheFleetsShape() throws {
        let store = SlotPreferenceStore(defaults: defaults)
        store.setMotion(false, for: "ds")
        let json = try XCTUnwrap(defaults.string(forKey: SlotPreferenceStore.motionKey))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["slotId"] as? String, "ds")
        XCTAssertEqual(rows.first?["enabled"] as? Bool, false)
        XCTAssertEqual(SlotPreferenceStore.parse(json).map(\.0), ["ds"])
    }

    func testAGarbledBlobReadsAsNothingWritten() {
        defaults.set("not json", forKey: SlotPreferenceStore.motionKey)
        defaults.set(
            "[{\"slotId\":\"\",\"enabled\":false},{\"enabled\":true},{\"slotId\":\"ok\",\"enabled\":\"no\"}]",
            forKey: SlotPreferenceStore.rumbleKey
        )
        let store = SlotPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.state, [:], "every malformed row is dropped")
        XCTAssertTrue(SlotPreferenceStore.parse(nil).isEmpty)
    }

    func testTheSameSwitchTwiceIsOneChange() {
        let store = SlotPreferenceStore(defaults: defaults)
        var emissions = 0
        var bag = Set<AnyCancellable>()
        store.statePublisher.dropFirst().sink { _ in emissions += 1 }.store(in: &bag)
        store.setRumble(false, for: "ds")
        store.setRumble(false, for: "ds")
        XCTAssertEqual(emissions, 1)
    }
}
