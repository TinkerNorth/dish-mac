// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishCore
@testable import DishEngine

/// The five phases as the manager drives them, against a reference host
/// built from the same primitives: the host derives its key from the salt
/// and the PIN the dish minted, so a client that skipped a check is refused
/// by the host rather than by an assertion. The PIN is read the way the user
/// reads it, off the event the manager sends before any call.
@MainActor
final class MoonlightManagerPairingTests: MoonlightManagerTestCase {

    private var client: InMemoryMoonlightIdentity!
    private var referenceHost: ReferenceMoonlightHost!
    private let pins = LockedBox<[String]>([])

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let client = InMemoryMoonlightIdentity(), let hostIdentity = InMemoryMoonlightIdentity() else {
            throw XCTSkip("no RSA keys on this runner")
        }
        self.client = client
        identity = client
        makeManager()
        store.removeHost(id: host.id)
        let pins = pins
        referenceHost = ReferenceMoonlightHost(identity: hostIdentity, client: client) { pins.get().last ?? "" }
        // Nothing is paired yet, so the shortcut that confirms standing trust must not fire.
        gateway.answerSecure("/serverinfo", .unreachable)
        gateway.answerPlain("/serverinfo", .init(status: 200, body: Self.unpairedInfo))
        gateway.onPlain = { [referenceHost] request in referenceHost?.answer(request) }
        gateway.answerTrusting(.init(status: 200, body: "<root status_code=\"200\"><paired>1</paired></root>"))
    }

    private func watchForPins() {
        let pins = pins
        manager.events
            .sink { event in
                if case let .pairingPinReady(_, pin) = event { pins.mutate { $0.append(pin) } }
            }
            .store(in: &pinBag)
    }

    private var pinBag = Set<AnyCancellable>()

    private func failures() -> [MoonlightPairingFailure] {
        seen.compactMap { event in
            if case let .pairingFailed(_, reason) = event { return reason }
            return nil
        }
    }

    func testAHostThatAlreadyTrustsThisDeviceIsRecordedWithoutAPin() async {
        gateway.answerSecure("/serverinfo", .init(status: 200, body: Self.pairedInfo))
        let paired = await manager.pairHost(host)
        XCTAssertTrue(paired)
        XCTAssertEqual(store.host(id: host.id)?.paired, true, "the confirmed pairing has to persist")
        XCTAssertEqual(store.host(id: host.id)?.uniqueId, "abc")
        XCTAssertTrue(manager.verifiedHostIds.contains(host.id))
        XCTAssertEqual(gateway.count(.plain, "/pair"), 0, "confirming trust needs no PIN exchange at all")
        XCTAssertEqual(seen, [.paired(MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc"))])
        XCTAssertEqual(manager.pairingInFlight, [])
    }

    func testANeverPairedHostRunsAllFivePhasesAndEndsRecordedAsPaired() async {
        watchForPins()
        let paired = await manager.pairHost(host)
        XCTAssertTrue(paired, "the client says it paired")
        XCTAssertTrue(referenceHost.paired, "and the host agrees")
        XCTAssertEqual(store.host(id: host.id)?.paired, true)
        XCTAssertEqual(store.host(id: host.id)?.uniqueId, "abc", "the machine it paired with")
        XCTAssertEqual(pins.get().first?.count, 4)
        XCTAssertEqual(gateway.count(.plain, "/pair"), 4)
        XCTAssertEqual(gateway.count(.trusting, "/pair"), 1, "phase 5 over mutual TLS, trusting the certificate phases 1 to 4 proved")
        XCTAssertEqual(gateway.provenPins[host.id], referenceHost.certificateDER, "a confirmed pairing pins it")
        let phaseOne = gateway.calls.first { $0.kind == .plain && $0.path == "/pair" }
        XCTAssertEqual(phaseOne?.timeout, MoonlightHttpTransport.pinTimeout, "phase 1 is given the window the human needs")
        XCTAssertTrue(phaseOne?.query.contains("devicename=roth") ?? false)
        XCTAssertTrue(manager.verifiedHostIds.contains(host.id))
        XCTAssertEqual(seen.last, .paired(MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")))
    }

    func testEveryPhaseThatFailsNamesItselfAndLeavesNoHalfWrittenRecord() async {
        watchForPins()
        for phase in 1 ... 4 {
            referenceHost.stopAt = phase
            let paired = await manager.pairHost(host)
            XCTAssertFalse(paired)
            XCTAssertEqual(failures().last?.phase, phase)
            XCTAssertNil(store.host(id: host.id), "phase \(phase) must leave nothing behind")
        }
        XCTAssertEqual(failures().map(\.kind), [.noCertificate, .noChallengeResponse, .noPairingSecret, .notConfirmed])
        referenceHost.stopAt = nil
        gateway.answerTrusting(.unreachable)
        let unconfirmed = await manager.pairHost(host)
        XCTAssertFalse(unconfirmed)
        XCTAssertEqual(failures().last?.phase, 5)
        XCTAssertEqual(failures().last?.kind, .notConfirmed)
        XCTAssertNil(store.host(id: host.id))
        XCTAssertTrue(gateway.provenPins.isEmpty, "a pairing that does not end in a confirmed phase 5 changes no pin")
        XCTAssertEqual(pins.get().count, 5, "every attempt minted its own PIN")
    }

    func testAWrongPinIsCaughtOnThisSideAtPhaseThree() async {
        let pins = pins
        gateway.onPlain = { [referenceHost] request in
            pins.mutate { $0 = ["0000"] }
            return referenceHost?.answer(request)
        }
        let paired = await manager.pairHost(host)
        XCTAssertFalse(paired)
        XCTAssertEqual(failures().last?.phase, 3)
        XCTAssertEqual(failures().last?.kind, .hostNotAuthentic, "the hash the host committed to does not match")
        XCTAssertNil(store.host(id: host.id))
    }

    func testAPhaseTheHostRefusesInItsOwnWordsIsReportedInThem() async {
        let held = "A pairing session with this uniqueid already exists"
        gateway.onPlain = nil
        gateway.answerPlain("/pair", .init(status: 200, body: "<root status_code=\"409\" status_message=\"\(held)\"/>"))
        let paired = await manager.pairHost(host)
        XCTAssertFalse(paired)
        XCTAssertEqual(failures(), [MoonlightPairingFailure(phase: 1, kind: .noCertificate, httpStatus: 200, hostSaid: held)])
    }

    func testACancelledPairingWritesNothingAndSaysNothingMore() async {
        watchForPins()
        let hold = gateway.holdPlain("/pair")
        let current: MoonlightConnectionManager = manager
        let pairing = Task { @MainActor [host] in await current.pairHost(host) }
        let asked = await waitUntil { hold.asked }
        XCTAssertTrue(asked, "phase 1 is waiting for the PIN")
        manager.cancelPairing(hostId: host.id)
        hold.answer(.init(status: 200, body: "<root status_code=\"200\"><paired>0</paired></root>"))
        let paired = await pairing.value
        XCTAssertFalse(paired)
        XCTAssertNil(store.host(id: host.id))
        XCTAssertEqual(seen.count, 1, "the PIN was offered, and nothing more was said")
    }

    func testAHostForgottenWhileItsPinIsOnScreenIsNotWrittenBackByThePinTypedAfter() async {
        rememberPaired(paired: false)
        watchForPins()
        let hold = gateway.holdPlain("/pair")
        let current: MoonlightConnectionManager = manager
        let pairing = Task { @MainActor [host] in await current.pairHost(host) }
        let asked = await waitUntil { hold.asked }
        XCTAssertTrue(asked)
        manager.forget(hostId: host.id)
        await manager.awaitQuiet()
        hold.answer(.init(status: 200, body: "<root status_code=\"200\"><paired>0</paired></root>"))
        let paired = await pairing.value
        XCTAssertFalse(paired)
        XCTAssertNil(store.host(id: host.id), "the host is not remembered")
        XCTAssertFalse(seen.contains { if case .paired = $0 { true } else { false } })
    }

    func testACompletedPairingRecordsTheUniqueIdOfTheMachineItPairedWith() async {
        rememberPaired(uniqueId: "host-1", paired: false)
        gateway.answerPlain("/serverinfo", .init(status: 200, body: Self.unpairedInfo.replacingOccurrences(of: "abc", with: "host-2")))
        watchForPins()
        let paired = await manager.pairHost(MoonlightHost(name: "PC", address: host.address, uniqueId: "host-1"))
        XCTAssertTrue(paired)
        XCTAssertEqual(store.host(id: host.id)?.uniqueId, "host-2", "the PIN proves the machine that answers now")
        gateway.answerPlain("/serverinfo", .unreachable)
        gateway.answerSecure("/serverinfo", .init(status: 200, body: Self.pairedInfo))
        _ = await manager.pairHost(MoonlightHost(name: "PC", address: host.address, uniqueId: "host-1"))
        XCTAssertEqual(
            store.host(id: host.id)?.uniqueId,
            "host-2",
            "a pairing that cannot ask the host its uniqueid keeps the one remembered"
        )
    }

    func testPairingWithoutAnIdentityFails() async {
        identity = nil
        makeManager()
        let paired = await manager.pairHost(host)
        XCTAssertFalse(paired)
        XCTAssertEqual(failures().map(\.kind), [.noIdentity])
    }
}
