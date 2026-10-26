// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// The two first-run flags under the desktops' and Android's keys: the
/// welcome is shown until it is skipped or finished, and the Local Network
/// prompt is explained until the first scan runs. Both survive a relaunch.
final class OnboardingPreferenceStoreTests: XCTestCase {

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

    private var store: OnboardingPreferenceStore {
        OnboardingPreferenceStore(defaults: defaults)
    }

    func testAFirstRunHasSeenNeitherTheWelcomeNorThePrompt() {
        XCTAssertFalse(store.welcomeCompleted)
        XCTAssertFalse(store.localNetworkPrimed)
    }

    func testFinishingTheWelcomeIsRememberedUnderTheFleetsKey() {
        store.markWelcomeComplete()
        XCTAssertTrue(defaults.bool(forKey: "onboarding_welcome_completed"))
        XCTAssertTrue(store.welcomeCompleted, "a new store over the same defaults reads it back")
        XCTAssertFalse(store.localNetworkPrimed, "the two flags are separate")
    }

    func testPrimingTheLocalNetworkIsRememberedUnderAndroidsKey() {
        store.markLocalNetworkPrimed()
        XCTAssertTrue(defaults.bool(forKey: "local_network_primed"))
        XCTAssertTrue(store.localNetworkPrimed)
        XCTAssertFalse(store.welcomeCompleted)
    }

    func testResettingTheWelcomeShowsItAgainAndKeepsThePriming() {
        store.markWelcomeComplete()
        store.markLocalNetworkPrimed()
        store.resetWelcome()
        XCTAssertFalse(store.welcomeCompleted)
        XCTAssertTrue(store.localNetworkPrimed)
    }
}
