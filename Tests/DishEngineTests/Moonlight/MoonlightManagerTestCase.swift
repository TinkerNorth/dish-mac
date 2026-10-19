// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishCore
@testable import DishEngine

/// The manager over scripted seams: a host at 10.0.0.5 remembered as paired
/// with Desktop picked, a gateway that answers paired and launches, and edges
/// that stream. Each suite narrows what it needs.
@MainActor
class MoonlightManagerTestCase: XCTestCase {
    static let pairedInfo = "<root status_code=\"200\"><hostname>PC</hostname><uniqueid>abc</uniqueid>"
        + "<PairStatus>1</PairStatus><currentgame>0</currentgame></root>"
    static let unpairedInfo = "<root status_code=\"200\"><hostname>PC</hostname><uniqueid>abc</uniqueid>"
        + "<PairStatus>0</PairStatus><currentgame>0</currentgame></root>"
    static let appList = "<root status_code=\"200\"><App><AppTitle>Desktop</AppTitle><ID>1</ID></App></root>"
    static let twoApps = "<root status_code=\"200\"><App><AppTitle>Desktop</AppTitle><ID>1</ID></App>"
        + "<App><AppTitle>Steam</AppTitle><ID>2</ID></App></root>"
    static let launchOk = "<root status_code=\"200\"><sessionUrl0>rtsp://10.0.0.5:48010</sessionUrl0><gamesession>1</gamesession></root>"
    static let refusedLaunch = "<root status_code=\"401\" status_message=\"Unauthorized\"/>"
    static let cancelled = "<root status_code=\"200\"><cancel>1</cancel></root>"

    /// The host as the store remembers it, uniqueid included: what every event names.
    let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    let xbox = MoonlightAnnouncedPad(type: MoonlightControllerType.xbox, capabilities: 0x03, supportedButtons: 0xF7FF)
    let playStation = MoonlightAnnouncedPad(type: MoonlightControllerType.playStation, capabilities: 0xFF, supportedButtons: 0x10F7FF)
    var defaults: UserDefaults!
    var suite: String!
    var store: MoonlightHostStore!
    var gateway: ScriptedMoonlightGateway!
    var edges: FakeMoonlightEdges!
    var manager: MoonlightConnectionManager!
    var seen: [MoonlightConnectionEvent] = []
    var discovered: [MoonlightHost] = []
    var identity: InMemoryMoonlightIdentity?
    private var bag = Set<AnyCancellable>()

    /// XCTest runs `setUpWithError` before `setUp`, so the seams are built
    /// here and a suite that narrows them overrides this after calling up.
    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = MoonlightHostStore(defaults: defaults)
        gateway = ScriptedMoonlightGateway()
        gateway.answerPlain("/serverinfo", .init(status: 200, body: Self.pairedInfo))
        gateway.answerSecure("/serverinfo", .init(status: 200, body: Self.pairedInfo))
        gateway.answerSecure("/applist", .init(status: 200, body: Self.appList))
        gateway.answerSecure("/launch", .init(status: 200, body: Self.launchOk))
        gateway.answerSecure("/cancel", .init(status: 200, body: Self.cancelled))
        edges = FakeMoonlightEdges()
        rememberPaired(appId: "1", appName: "Desktop")
        makeManager()
    }

    override func tearDown() {
        bag.removeAll()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func makeManager() {
        bag.removeAll()
        manager = MoonlightConnectionManager(
            store: store,
            gateway: gateway,
            identity: identity,
            edges: edges,
            discover: { [weak self] in self?.discovered ?? [] },
            random: { count in Data(repeating: 0x42, count: count) },
            nonce: { "nonce" }
        )
        manager.events
            .sink { [weak self] event in self?.seen.append(event) }
            .store(in: &bag)
    }

    func rememberPaired(appId: String = "", appName: String = "", uniqueId: String = "abc", paired: Bool = true) {
        var record = RememberedMoonlightHost(host: host, paired: paired)
        record.uniqueId = uniqueId
        record.lastAppId = appId
        record.lastAppName = appName
        store.put(record)
        manager?.publishRemembered()
    }

    func pad(_ slotId: String, _ announced: MoonlightAnnouncedPad? = nil) -> MoonlightPadRequest {
        MoonlightPadRequest(slotId: slotId, announced: announced ?? xbox)
    }

    /// Bind these slots to the host and wait for the converge to land.
    func bind(_ slots: String...) async {
        manager.applyDesired([host.id: slots.map { pad($0) }])
        await manager.awaitQuiet()
    }

    func connection() -> MoonlightConnection? {
        manager.get(host.id)
    }

    func launches() -> Int {
        gateway.count(.secure, "/launch")
    }

    func cancels() -> Int {
        gateway.count(.secure, "/cancel")
    }

    func resumes() -> Int {
        gateway.count(.secure, "/resume")
    }

    func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 200 where !predicate() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }
}
