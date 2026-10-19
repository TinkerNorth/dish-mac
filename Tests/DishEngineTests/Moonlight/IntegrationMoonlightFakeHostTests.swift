// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Moonlight path end to end against a host on loopback, over the real
// sockets: the mutual-TLS gateway with its pins, the five pairing phases, the
// RTSP handshake, the media pings and the ENet control link, driven by the
// real manager the way the app drives it. The host is FakeMoonlightHost: it
// answers as Sunshine and Wolf do and opens every sealed packet, so the
// assertions read what a host would have read. Every wait is bounded.

import Combine
import Security
import XCTest
@testable import DishCore
@testable import DishEngine

@MainActor
final class IntegrationMoonlightFakeHostTests: XCTestCase {
    private var fake: FakeMoonlightHost!
    private var hostIdentity: MoonlightIdentityStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: MoonlightHostStore!
    private var pins: MemoryPins!
    private var manager: MoonlightConnectionManager!
    private var seen: [MoonlightConnectionEvent] = []
    private var bag = Set<AnyCancellable>()
    /// The PIN the manager showed, which the host's operator types in; or a
    /// wrong one, when the test says so.
    private let pin = LockedBox<String>("")
    private let typedWrong = LockedBox<Bool>(false)
    private let xbox = MoonlightAnnouncedPad(type: MoonlightControllerType.xbox, capabilities: 0x03, supportedButtons: 0xF7FF)

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let keychain = FakeSatelliteThrowawayKeychain.shared,
              let client = MoonlightIdentityStore.loadOrCreate(keychain: keychain),
              let hostKeychain = FakeSatelliteThrowawayKeychain.another(),
              let host = MoonlightIdentityStore.loadOrCreate(keychain: hostKeychain),
              let tls = host.secIdentity() else
        {
            throw XCTSkip("no keychain-backed identities on this runner")
        }
        hostIdentity = host
        let pin = pin
        let typedWrong = typedWrong
        fake = FakeMoonlightHost(identity: host, tlsIdentity: tls, client: client, pin: {
            let shown = pin.get()
            return typedWrong.get() ? (shown == "0000" ? "1111" : "0000") : shown
        })
        try fake.start()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = MoonlightHostStore(defaults: defaults)
        pins = MemoryPins()
        manager = MoonlightConnectionManager(
            store: store,
            gateway: MoonlightGateway(identity: client, pins: pins),
            identity: client,
            edges: LiveMoonlightSessionEdges(),
            discover: { [] },
            random: { count in Data(repeating: 0x42, count: count) },
            nonce: { "nonce" }
        )
        manager.events
            .sink { [weak self] event in
                self?.seen.append(event)
                if case let .pairingPinReady(_, shown) = event { self?.pin.set(shown) }
            }
            .store(in: &bag)
        store.put(RememberedMoonlightHost(host: fake.host, paired: false))
        manager.publishRemembered()
    }

    override func tearDown() {
        manager?.applyDesired([:])
        fake?.stop()
        bag.removeAll()
        if let suite { defaults.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    // MARK: - The journey

    func testPairsProbesStreamsCarriesInputAndFeedbackAndHandsTheAppBack() async throws {
        let host = fake.host
        let paired = await manager.pairHost(host)
        XCTAssertTrue(paired)
        XCTAssertTrue(fake.pairing.paired, "the host verified the dish's secret in phase 4")
        XCTAssertEqual(pins.certPin(host: host.id), hostIdentity.fingerprintHex, "phase 5 proved the certificate that is now the pin")
        XCTAssertTrue(seen.contains { if case .paired = $0 { true } else { false } })

        let probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .paired)
        XCTAssertEqual(probe.apps.map(\.title), ["Desktop"])

        manager.applyDesired([host.id: [MoonlightPadRequest(slotId: "pad-a", announced: xbox)]])
        await manager.awaitQuiet()
        let connection = try XCTUnwrap(manager.get(host.id))
        let streaming = await eventually { connection.isStreaming }
        XCTAssertTrue(streaming, "the launch, the RTSP handshake and the control handshake all landed")
        try assertLaunchAndHandshake()
        try await assertPadAnnouncedAndInputCarried(connection)
        await assertFeedbackAndPings(connection)

        manager.applyDesired([:])
        await manager.awaitQuiet()
        let ended = await eventually {
            let seen = self.fake.control.snapshot()
            return seen.terminations == 1 && seen.disconnects == 1 && self.fake.cancelCount() == 1
        }
        let afterwards = fake.control.snapshot()
        XCTAssertTrue(
            ended,
            "the last pad leaving ends the session: TERMINATION, DISCONNECT, then /cancel; saw \(afterwards), cancels \(fake.cancelCount())"
        )
        XCTAssertFalse(connection.isStreaming)
    }

    func testAPinTypedWrongIntoTheHostIsRefusedByTheDishAndNothingIsWritten() async {
        typedWrong.set(true)
        let host = fake.host
        let paired = await manager.pairHost(host)
        XCTAssertFalse(paired)
        XCTAssertFalse(fake.pairing.paired, "the dish's secret never reached the host")
        XCTAssertEqual(store.host(id: host.id)?.paired, false)
        XCTAssertFalse(manager.verifiedHostIds.contains(host.id))
        // The pin is from first sight, as every mutual-TLS call pins on first use;
        // a pairing proves it (phase 5) and a refused one leaves it as it was.
        XCTAssertEqual(pins.certPin(host: host.id), hostIdentity.fingerprintHex)
        let refused = seen.compactMap { event -> MoonlightPairingFailure? in
            if case let .pairingFailed(_, reason) = event { return reason }
            return nil
        }
        XCTAssertEqual(refused.map(\.kind), [.hostNotAuthentic], "the hash the host built under its PIN did not reproduce")
    }

    // MARK: - The pieces of the journey

    private func assertLaunchAndHandshake() throws {
        let launches = fake.launches()
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(try XCTUnwrap(launches.first).contains("rikey=" + String(repeating: "42", count: 16)), "the key the manager minted")
        let commands = fake.rtsp.requests.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(commands, ["OPTIONS", "DESCRIBE", "SETUP", "SETUP", "SETUP", "ANNOUNCE", "PLAY"])
    }

    private func assertPadAnnouncedAndInputCarried(_ connection: MoonlightConnection) async throws {
        let announced = await eventually {
            let seen = self.fake.control.snapshot()
            return seen.arrivals.count == 1 && !seen.frames.isEmpty
        }
        XCTAssertTrue(announced, "the arrival and the rest frame behind it")
        let seen = fake.control.snapshot()
        XCTAssertEqual(seen.connects, 1)
        XCTAssertEqual(seen.unopened, 0, "every packet opened with the launch's rikey")
        let arrival = try XCTUnwrap(seen.arrivals.first)
        XCTAssertEqual(arrival, .init(number: 0, type: MoonlightControllerType.xbox, capabilities: 0x03, buttons: 0xF7FF))
        XCTAssertEqual(seen.frames.first, .init(number: 0, mask: 0x0001, buttons: 0))

        connection.link.sendReport("pad-a", GamepadReport(buttons: 0x1000))
        let pressed = await eventually { self.fake.control.snapshot().frames.contains { $0.buttons == 0x1000 } }
        XCTAssertTrue(pressed, "A reached the host in a frame sealed with the session key")
    }

    private func assertFeedbackAndPings(_ connection: MoonlightConnection) async {
        let feedback = LockedBox<[MoonlightEvent]>([])
        connection.setFeedbackHandler { event in feedback.mutate { $0.append(event) } }
        fake.control.sendEvent(Self.rumble(controller: 0, low: 0x1000, high: 0x2000))
        let rumbled = await eventually { feedback.get().contains(.rumble(controller: 0, low: 0x1000, high: 0x2000)) }
        XCTAssertTrue(rumbled, "the host's event came back through the link")
        let pinged = await eventually { self.fake.video.count() > 0 && self.fake.audio.count() > 0 }
        XCTAssertTrue(pinged, "both media ports are kept alive")
        let keptAlive = await eventually { self.fake.control.snapshot().keepalives >= 1 }
        XCTAssertTrue(keptAlive, "the protocol's own keepalive flows while no input does")
    }

    /// RUMBLE_DATA as Wolf sends it: an unused word, then the controller and
    /// the two motors, little-endian.
    private static func rumble(controller: UInt16, low: UInt16, high: UInt16) -> Data {
        var writer = ByteWriter(capacity: 14)
        writer.u16LE(MoonlightProtocol.eventRumbleData)
        writer.u16LE(10)
        writer.u32LE(0)
        writer.u16LE(controller)
        writer.u16LE(low)
        writer.u16LE(high)
        return writer.data
    }

    /// Polls on the main actor until `predicate` holds or ten seconds pass:
    /// loopback TLS handshakes and the RTSP's seven connections take real
    /// time, and nothing here sleeps for a fixed span.
    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 500 where !predicate() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}
