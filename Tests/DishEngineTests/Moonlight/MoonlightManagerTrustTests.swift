// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The trust half: what the probe says and writes, discovery that merges,
/// durable interest kept apart from trust, the app pick, and forget.
@MainActor
final class MoonlightManagerTrustTests: MoonlightManagerTestCase {

    func testTheProbeVerdicts() async {
        var probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .paired)
        XCTAssertTrue(probe.appsFetched)
        XCTAssertEqual(probe.apps.map(\.id), ["1"])
        XCTAssertTrue(manager.verifiedHostIds.contains(host.id))
        gateway.answerSecure("/applist", .init(status: 401, body: ""))
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .paired, "a paired host whose list will not load still reads as paired")
        XCTAssertTrue(probe.appsFailed)
        gateway.answerSecure("/serverinfo", .init(status: 200, body: Self.unpairedInfo))
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .trustLost, "unpaired over mutual TLS with a pairing stored")
        gateway.answerSecure("/serverinfo", .unreachable)
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .trustLost, "mutual TLS refused with a pairing stored")
        gateway.answerPlain("/serverinfo", .init(status: 200, body: Self.pairedInfo.replacingOccurrences(of: "abc", with: "zzz")))
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .replaced, "another machine answers under the address")
        gateway.answerPlain("/serverinfo", .unreachable)
        let secureCalls = gateway.count(.secure, "/serverinfo")
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .remembered, "a paired host that stops answering")
        XCTAssertEqual(gateway.count(.secure, "/serverinfo"), secureCalls, "never asked over mutual TLS")
    }

    func testTheProbeVerdictsWithNoPairingStored() async {
        rememberPaired(paired: false)
        gateway.answerPlain("/serverinfo", .unreachable)
        var probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .unreachable, "interest is not a pairing")
        gateway.answerPlain("/serverinfo", .init(status: 200, body: Self.unpairedInfo))
        gateway.answerSecure("/serverinfo", .init(status: 200, body: Self.unpairedInfo))
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .notPaired)
        gateway.answerSecure("/serverinfo", .unreachable)
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .notPaired)
        gateway.answerSecure("/serverinfo", .init(status: 200, body: Self.pairedInfo))
        probe = await manager.probe(host)
        XCTAssertEqual(probe.trust, .paired, "the plaintext PairStatus is not an answer about pairing; only mutual TLS tells the truth")
    }

    func testTheFirstAnswerARememberedHostGivesRecordsItsUniqueIdAndThePickStays() async {
        rememberPaired(appId: "9", appName: "Removed", uniqueId: "", paired: false)
        _ = await manager.probe(host)
        XCTAssertEqual(store.host(id: host.id)?.uniqueId, "abc")
        XCTAssertEqual(store.host(id: host.id)?.lastAppId, "9", "the host's list is its word on what it can start; the pick is the user's")
        XCTAssertEqual(manager.hostFacts[host.id]?.hostname, "PC")
        gateway.answerSecure(
            "/applist",
            .init(status: 200, body: "<root status_code=\"200\"><App><AppTitle>Desktop</AppTitle><ID>1</ID></App><App><AppTi")
        )
        let cutOff = await manager.probe(host)
        XCTAssertTrue(cutOff.appsFailed, "a reply cut off mid-list says nothing")
        XCTAssertEqual(store.host(id: host.id)?.lastAppId, "9")
    }

    func testAScanMergesAndAnEmptyScanKeepsWhatWasFound() async {
        discovered = [host]
        manager.startDiscovery()
        XCTAssertTrue(manager.isScanning)
        manager.startDiscovery()
        let found = await waitUntil { [weak self] in self?.manager.isScanning == false }
        XCTAssertTrue(found)
        XCTAssertEqual(manager.discoveredHosts.map(\.id), [host.id])
        discovered = []
        manager.startDiscovery()
        _ = await waitUntil { [weak self] in self?.manager.isScanning == false }
        XCTAssertEqual(manager.discoveredHosts.map(\.id), [host.id], "one mDNS miss erases nothing")
        discovered = [MoonlightHost(name: "PC renamed", address: host.address)]
        manager.startDiscovery()
        _ = await waitUntil { [weak self] in self?.manager.isScanning == false }
        XCTAssertEqual(manager.discoveredHosts.map(\.name), ["PC renamed"], "refreshed in place, not duplicated")
    }

    func testAManuallyAddedHostIsRememberedAsInterestAndAnAddressNothingAnswersIsReported() async {
        store.removeHost(id: host.id)
        manager.addManualHost(" 10.0.0.5 ")
        let added = await waitUntil { [weak self] in self?.manager.discoveredHosts.isEmpty == false }
        XCTAssertTrue(added)
        XCTAssertEqual(manager.discoveredHosts.first?.id, host.id)
        XCTAssertEqual(manager.discoveredHosts.first?.manual, true)
        let record = store.host(id: host.id)
        XCTAssertEqual(record?.paired, false, "adding is not pairing")
        XCTAssertEqual(record?.uniqueId, "abc", "the typed address is answered with the uniqueid")
        XCTAssertEqual(record?.name, "PC")
        gateway.answerPlain("/serverinfo", .unreachable)
        manager.addManualHost("10.0.0.9")
        let reported = await waitUntil { [weak self] in self?.seen.isEmpty == false }
        XCTAssertTrue(reported)
        XCTAssertEqual(seen, [.noHostAnswered(address: "10.0.0.9")])
        XCTAssertNil(store.host(id: MoonlightHostStore.hostId(address: "10.0.0.9")))
        XCTAssertEqual(manager.discoveredHosts.count, 1)
    }

    func testInterestNeverPromotesOrDemotesAndAPickOnAHostWithNoRecordIsKept() {
        store.removeHost(id: host.id)
        manager.rememberInterest(host)
        XCTAssertEqual(store.host(id: host.id)?.paired, false)
        rememberPaired()
        manager.rememberInterest(host)
        XCTAssertEqual(store.host(id: host.id)?.paired, true, "interest never demotes")
        manager.rememberApp(hostId: host.id, appId: "7", appName: "Steam")
        XCTAssertEqual(store.host(id: host.id)?.lastAppId, "7")
        XCTAssertEqual(store.host(id: host.id)?.paired, true, "a pick does not disturb trust")
        store.removeHost(id: host.id)
        manager.rememberApp(hostId: host.id, appId: "1", appName: "Desktop")
        XCTAssertNil(store.host(id: host.id), "a host nothing knows cannot keep a pick")
        discovered = [host]
        manager.mergeDiscovered(host)
        manager.rememberApp(hostId: host.id, appId: "1", appName: "Desktop")
        XCTAssertEqual(manager.rememberedAppId(hostId: host.id), "1", "a discovered host's pick is kept, as interest")
        XCTAssertEqual(manager.rememberedAppName(hostId: host.id), "Desktop")
        XCTAssertEqual(store.host(id: host.id)?.paired, false)
        manager.rememberInterest(hostId: "moonlight:ghost")
        XCTAssertNil(store.host(id: "moonlight:ghost"), "remembering interest in an unknown host writes nothing")
        XCTAssertEqual(manager.rememberedEmulatedType(hostId: host.id), MoonlightControllerType.auto)
        manager.setEmulatedType(hostId: host.id, type: MoonlightControllerType.playStation)
        XCTAssertEqual(manager.rememberedEmulatedType(hostId: host.id), MoonlightControllerType.playStation)
        XCTAssertEqual(manager.rememberedHosts.map(\.id), [host.id], "the published list follows the store")
    }

    func testForgetLeavesNothingBehindAndClosesOnlyALiveSessionsApp() async {
        _ = await manager.probe(host)
        manager.mergeDiscovered(host)
        manager.rememberBinding(slotId: "ds", hostId: host.id, controllerType: 2)
        manager.rememberBinding(slotId: "xb", hostId: "moonlight:10.0.0.9", controllerType: 1)
        manager.forget(hostId: host.id)
        await manager.awaitQuiet()
        XCTAssertNil(store.host(id: host.id), "the record must go")
        XCTAssertFalse(manager.verifiedHostIds.contains(host.id), "the verification must go")
        XCTAssertNil(manager.hostFacts[host.id], "nor what it said about itself")
        XCTAssertTrue(manager.discoveredHosts.isEmpty, "the discovery row must go")
        XCTAssertNil(manager.get(host.id))
        XCTAssertEqual(gateway.count(.forgetPin, ""), 1, "the pin used to survive a forget")
        XCTAssertEqual(manager.rememberedBindings.map(\.slotId), ["xb"], "every binding remembered for it, and no other host's")
        XCTAssertEqual(cancels(), 0, "a host that never had a session cancels nothing")
        XCTAssertEqual(manager.rememberedHosts, [])
    }

    func testForgettingAHostWithALiveSessionClosesTheAppBeforeThePinGoes() async {
        await bind("a")
        manager.forget(hostId: host.id)
        await manager.awaitQuiet()
        XCTAssertEqual(cancels(), 1)
        let cancelAt = gateway.calls.firstIndex { $0.kind == .secure && $0.path == "/cancel" } ?? -1
        let forgetAt = gateway.calls.firstIndex { $0.kind == .forgetPin } ?? -1
        XCTAssertTrue(cancelAt >= 0 && cancelAt < forgetAt, "the cancel rides mutual TLS, so it goes while the pin is still there")
        XCTAssertNil(manager.get(host.id))
        XCTAssertEqual(manager.sessionHostIds, [])
    }

    func testAHostForgottenWhileAProbeAsksItIsNotWrittenBack() async {
        let hold = gateway.holdSecure("/serverinfo")
        let current: MoonlightConnectionManager = manager
        let probing = Task { @MainActor [host] in await current.probe(host) }
        let asked = await waitUntil { hold.asked }
        XCTAssertTrue(asked)
        manager.forget(hostId: host.id)
        await manager.awaitQuiet()
        hold.answer(.init(status: 200, body: Self.pairedInfo))
        let probe = await probing.value
        XCTAssertEqual(probe.trust, .notPaired, "nothing is held for a forgotten host")
        XCTAssertFalse(manager.verifiedHostIds.contains(host.id))
        XCTAssertNil(manager.hostFacts[host.id])
        XCTAssertEqual(gateway.count(.secure, "/applist"), 0, "and it is asked nothing more")
    }
}
