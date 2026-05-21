// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import Dish

/// Pins the persistent `staleSatelliteIds` set-mutation contract on
/// `WifiConnectionManager` and the `LinkState.stale` derivation it drives in
/// `ConnectionHub.rebuild`. These tests cover the seam — the set itself,
/// `markStale` / `clearStale`, and the rebuild wiring — without standing up a
/// live socket, mirroring the `staleSatelliteIds` test approach in
/// dish-android's `SatelliteConnectionManager` coverage.
///
/// The set is the persistent counterpart to the transient `SessionState.stale`
/// added in 5910189: a "Needs pairing" marker that survives the
/// disconnect+silent-retry tear-down cycle, so a satellite the server has
/// forgotten stays on the `.stale` chip until either a fresh user-initiated
/// pair re-establishes it or the user explicitly forgets it.
@MainActor
final class StaleSatelliteIdsTests: XCTestCase {

    /// A throwaway `UserDefaults` suite so a test's `ConnectionStore`
    /// state doesn't bleed into the developer's real preferences or across
    /// tests in this file.
    private func makeStore() -> (ConnectionStore, UserDefaults, String) {
        let name = "dish.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("could not create isolated UserDefaults test suite")
        }
        return (ConnectionStore(defaults: defaults), defaults, name)
    }

    /// A satellite-id matching the `wifi:<ip>:<port>` shape
    /// `DiscoveredServer.id` produces. Hard-coded so the assertions read
    /// against a concrete value.
    private static let sampleId = "wifi:192.0.2.42:9876"
    private static let sampleId2 = "wifi:192.0.2.43:9876"

    // MARK: - Set-mutation semantics on WifiConnectionManager

    func testFreshManagerStartsWithEmptyStaleSet() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        XCTAssertTrue(wifi.staleSatelliteIds.isEmpty)
    }

    func testMarkStaleInsertsId() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.markStale(Self.sampleId)
        XCTAssertEqual(wifi.staleSatelliteIds, [Self.sampleId])
    }

    func testMarkStaleIsIdempotent() {
        // Calling mark twice on the same id must not duplicate it — Set
        // semantics, mirroring the Android `MutableStateFlow.update { if (id
        // in it) it else it + id }` short-circuit.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.markStale(Self.sampleId)
        wifi.markStale(Self.sampleId)
        wifi.markStale(Self.sampleId)
        XCTAssertEqual(wifi.staleSatelliteIds, [Self.sampleId])
    }

    func testMarkStaleMultipleIdsCoexist() {
        // The set keys per satellite — two unrelated stale servers stay
        // independent. Important: the user could have two paired-then-
        // forgotten satellites at once.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.markStale(Self.sampleId)
        wifi.markStale(Self.sampleId2)
        XCTAssertEqual(wifi.staleSatelliteIds, [Self.sampleId, Self.sampleId2])
    }

    func testClearStaleRemovesId() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.markStale(Self.sampleId)
        wifi.clearStale(Self.sampleId)
        XCTAssertTrue(wifi.staleSatelliteIds.isEmpty)
    }

    func testClearStaleOnUnknownIdIsNoOp() {
        // Idempotency the other way — clearing an id that was never stale
        // must not crash or somehow add it. Keeps `forget` safe to call on
        // arbitrary ids.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.clearStale(Self.sampleId)
        XCTAssertTrue(wifi.staleSatelliteIds.isEmpty)
    }

    func testClearStaleLeavesOtherIdsUntouched() {
        // Cross-id isolation: clearing one stale satellite must not also
        // silently re-pair another the user hasn't touched.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.markStale(Self.sampleId)
        wifi.markStale(Self.sampleId2)
        wifi.clearStale(Self.sampleId)
        XCTAssertEqual(wifi.staleSatelliteIds, [Self.sampleId2])
    }

    func testForgetClearsStaleMarker() {
        // `forget` is the user-initiated escape hatch — a forgotten
        // satellite must not leave a dangling `.stale` chip on a row that
        // no longer exists.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        wifi.markStale(Self.sampleId)
        wifi.forget(id: Self.sampleId)
        XCTAssertTrue(wifi.staleSatelliteIds.isEmpty)
    }

    // MARK: - @Published emission

    func testMarkStaleEmitsOnPublishedStream() {
        // The hub subscribes to `$staleSatelliteIds`; if the @Published
        // wrapper ever silently dropped emissions, the row chip would stop
        // updating. Pin that at least one emission occurs on a fresh mark.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let wifi = WifiConnectionManager(store: store)
        var emissions: [Set<String>] = []
        var bag = Set<AnyCancellable>()
        wifi.$staleSatelliteIds
            .sink { emissions.append($0) }
            .store(in: &bag)

        wifi.markStale(Self.sampleId)
        // First emission is the initial empty set from `sink` subscribing
        // to a CurrentValueSubject-like @Published; the second is the
        // mark.
        XCTAssertGreaterThanOrEqual(emissions.count, 2)
        XCTAssertEqual(emissions.last, [Self.sampleId])
    }

    // MARK: - ConnectionHub.rebuild derivation

    /// `@Published` fires in `willSet`, before the mutation is visible to
    /// downstream subscribers, so `ConnectionHub` defers its rebuild one
    /// run-loop tick to read the post-mutation value. Tests have to do the
    /// same: spin the main run loop until the published `connections`
    /// reflects the predicate (or fail). 1s is a generous ceiling — in
    /// practice the rebuild fires on the next async tick.
    private func waitForLink(
        _ hub: ConnectionHub,
        _ id: String,
        equals target: LinkState,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if hub.summary(id)?.live == target { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            hub.summary(id)?.live,
            target,
            "hub link state never reached \(target) for \(id)",
            file: file,
            line: line
        )
    }

    func testHubSurfacesStaleChipForRememberedServerInStaleSet() {
        // The end-to-end UI contract: a paired server with no live session
        // that's in `staleSatelliteIds` must surface `.stale`
        // ("Needs pairing"), *not* `.saved` / `.ready`. This is what makes
        // the marker user-visible.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let server = DiscoveredServer(name: "Sat", ip: "192.0.2.42", udpPort: 9876)
        store.remember(server)
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)

        wifi.markStale(server.id)
        waitForLink(hub, server.id, equals: .stale)
    }

    func testHubFallsBackToSavedWhenNotStale() {
        // Counterfactual to the above — without the marker, the same
        // paired-not-seen server reads `.saved`. Pins that
        // `staleSatelliteIds` is the *only* thing flipping the chip; if
        // the rebuild logic were inverted we'd see `.stale` here.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let server = DiscoveredServer(name: "Sat", ip: "192.0.2.42", udpPort: 9876)
        store.remember(server)
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)

        waitForLink(hub, server.id, equals: .saved)
    }

    func testHubClearsStaleChipWhenManagerClears() {
        // The clear hook (called in `openSession` on a successful
        // authenticated session and in `forget`) must reach the hub. If
        // the `$staleSatelliteIds` subscription regressed, the chip would
        // stick on `.stale` forever after a successful re-pair.
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        let server = DiscoveredServer(name: "Sat", ip: "192.0.2.42", udpPort: 9876)
        store.remember(server)
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)

        wifi.markStale(server.id)
        waitForLink(hub, server.id, equals: .stale)

        wifi.clearStale(server.id)
        waitForLink(hub, server.id, equals: .saved)
    }
}
