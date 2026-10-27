// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// Each pad's input-source machine on the main actor: Nintendo pads go
/// Direct by model, other pads only once GameController has settled on not
/// reading them, a real change proves a pad, a check hears each source once
/// and yields its verdict, and a pick moves a model only where its path is
/// available, remembered under `usb_path_choices`.
@MainActor
final class InputPathsTests: XCTestCase {

    private static let n64 = "hid:057e:2019"
    private static let pro = "hid:057e:2009"
    private static let proCarrier = "gc:Nintendo:Switch Pro Controller"

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!
    private var clock: PathClock!
    private var host: FakePathHost!
    private var paths: InputPaths!
    private let processor = GamepadInputProcessor()
    private let posts = LockedBox<[InputSource]>([])
    private var records: [InputPathRecord] = []
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
        scheduler = ManualPathScheduler()
        clock = PathClock()
        host = FakePathHost()
        paths = makePaths()
    }

    override func tearDown() {
        bag.removeAll()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makePaths() -> InputPaths {
        let clock = clock
        let made = InputPaths(choices: UsbPathChoiceStore(defaults: defaults), reader: reader, scheduler: scheduler) { clock?.read() ?? 0 }
        made.host = host
        made.start(processor: processor)
        made.records.sink { [weak self] record in self?.records.append(record) }.store(in: &bag)
        return made
    }

    /// A lane on the reader's wiring whose posts are also counted here.
    @discardableResult
    private func arrive(productId: Int, slotId: String, support: [Bool] = [true]) throws -> HidPadArrival {
        try arrive(DirectFixtures.nintendoProperties(productId: productId), slotId: slotId, support: support)
    }

    @discardableResult
    private func arrive(_ properties: [String: Any], slotId: String, support: [Bool]) throws -> HidPadArrival {
        let wiring = try XCTUnwrap(reader.wiring)
        let posts = posts
        let counted = HidPadWiring(
            processor: wiring.processor,
            notify: { key, source in
                posts.set(posts.get() + [source])
                wiring.notify(key, source)
            },
            battery: wiring.battery
        )
        let lane = try DirectFixtures.lane(DirectFixtures.candidate(properties), slotId: slotId, wiring: counted)
        let scripted = ScriptedSupport(support)
        let arrival = HidPadArrival(slotId: slotId, lane: lane, probe: GameControllerProbe { scripted.answer() })
        paths.hidPadArrived(arrival)
        return arrival
    }

    @discardableResult
    private func attachProCarrier(hasRumble: Bool = true) -> PadGate {
        paths.gameControllerAttached(id: Self.proCarrier, name: "Nintendo", category: "Switch Pro Controller", hasRumble: hasRumble)
    }

    private func storedChoices() -> [String: String]? {
        defaults.dictionary(forKey: UsbPathChoiceStore.choicesKey) as? [String: String]
    }

    // MARK: - Deciding

    func testTheReaderStartsOnTheProcessorItPublishesInto() throws {
        XCTAssertTrue(try XCTUnwrap(reader.wiring).processor === processor)
        XCTAssertNotNil(reader.events)
    }

    func testTheN64IsDirectAtOnceWithItsSlotAndItsReason() throws {
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        let slot = try XCTUnwrap(host.directSlots[Self.n64])
        XCTAssertEqual(slot.name, "Nintendo N64 Online Controller")
        XCTAssertEqual(slot.family, .nintendo)
        XCTAssertTrue(slot.capabilities.hasBattery, "the battery rides every Switch report")
        XCTAssertFalse(slot.capabilities.hasMotion, "the N64 pad has no IMU")
        XCTAssertFalse(slot.capabilities.hasRumble, "no carrier, no rumble")
        let facts = try XCTUnwrap(paths.state[Self.n64])
        XCTAssertEqual(facts.source, .direct)
        XCTAssertEqual(facts.reason, .directByModel)
        XCTAssertFalse(facts.proven)
        XCTAssertEqual(facts.picks, [], "the N64 is never offered Standard")
        XCTAssertEqual(facts.rumble, .noCarrier)
        XCTAssertEqual(facts.transport, .usb)
        XCTAssertEqual(facts.hardwareId, HidHardwareId(vendorId: 0x057E, productId: 0x2019))
        XCTAssertEqual(facts.rawReportHz, 0)
        XCTAssertEqual(arrival.lane.gate.routed, .direct)
        XCTAssertTrue(arrival.lane.gate.awaitsEvent(.direct), "unproven: the first change is wanted")
        XCTAssertEqual(records.first, InputPathRecord(subject: "Nintendo N64 Online Controller", note: .chosen(.direct, .directByModel)))
    }

    func testGameControllersAnswerNeverMovesANintendoPadOffDirect() throws {
        try arrive(productId: 0x2019, slotId: Self.n64, support: [true])
        scheduler.advance(ms: 100)
        XCTAssertEqual(paths.state[Self.n64]?.source, .direct)
        XCTAssertEqual(reader.released, [])
    }

    func testAPadGameControllerRejectsIsDirectOnlyOnceTheSettleEnds() throws {
        try arrive(DirectFixtures.gamepadProperties(), slotId: "hid:1234:5678", support: [false])
        XCTAssertNil(paths.state["hid:1234:5678"], "nothing is decided while GameController may still take it")
        XCTAssertNil(host.directSlots["hid:1234:5678"])
        scheduler.advance(ms: 30)
        let facts = try XCTUnwrap(paths.state["hid:1234:5678"])
        XCTAssertEqual(facts.source, .direct)
        XCTAssertEqual(facts.reason, .macOSCannotRead)
        XCTAssertTrue(facts.layoutGuessed)
        XCTAssertEqual(facts.rumble, .notCarried)
        XCTAssertEqual(host.directSlots["hid:1234:5678"]?.capabilities.hasBattery, false, "a generic pad reports no battery")
    }

    func testAPadGameControllerTakesOnASecondLookIsLeftToIt() throws {
        try arrive(DirectFixtures.gamepadProperties(), slotId: "hid:1234:5678", support: [false, true])
        scheduler.advance(ms: 10)
        XCTAssertEqual(reader.released, ["hid:1234:5678"])
        XCTAssertNil(paths.state["hid:1234:5678"])
        XCTAssertNil(host.directSlots["hid:1234:5678"])
    }

    // MARK: - Proof and the check

    func testTheFirstRealChangeProvesThePadAndLowersTheBits() throws {
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        feedReport(DirectFixtures.n64Idle, to: arrival.lane)
        feedReport(DirectFixtures.n64PressedA, to: arrival.lane)
        spinMainUntil { paths.state[Self.n64]?.proven == true }
        XCTAssertEqual(paths.state[Self.n64]?.proven, true)
        XCTAssertFalse(arrival.lane.gate.awaitsEvent(.direct))
        XCTAssertFalse(arrival.lane.gate.awaitsEvent(.standard))
    }

    func testACheckHearsTheDirectSourceOnceAndConcludesThatDishReadsIt() throws {
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        feedReport(DirectFixtures.n64Idle, to: arrival.lane)
        feedReport(DirectFixtures.n64PressedA, to: arrival.lane)
        spinMainUntil { paths.state[Self.n64]?.proven == true }
        posts.set([])
        paths.startCheck(slotId: Self.n64)
        XCTAssertEqual(paths.state[Self.n64]?.check, .running(sinceMs: clock.nowMs))
        for _ in 0 ..< 10 {
            feedReport(DirectFixtures.n64Idle, to: arrival.lane)
            feedReport(DirectFixtures.n64PressedA, to: arrival.lane)
        }
        spinMainUntil { paths.state[Self.n64]?.check != .running(sinceMs: clock.nowMs) }
        XCTAssertEqual(posts.get(), [.direct], "twenty changes, one event")
        XCTAssertEqual(paths.state[Self.n64]?.check, .concluded(.dishReadsIt, offer: CheckOffer.none))
        XCTAssertEqual(records.last?.note, .verdict(.dishReadsIt))
    }

    func testACheckThatHearsNothingForFiveSecondsGivesTheConnectionHint() throws {
        try arrive(productId: 0x2019, slotId: Self.n64)
        paths.startCheck(slotId: Self.n64)
        let timer = try XCTUnwrap(scheduler.liveTimers.first)
        clock.nowMs += 4000
        timer.fire()
        XCTAssertEqual(paths.state[Self.n64]?.check, .running(sinceMs: clock.nowMs - 4000), "four seconds in, still watching")
        clock.nowMs += 1000
        timer.fire()
        XCTAssertEqual(
            paths.state[Self.n64]?.check,
            .concluded(.nothingAtAll, offer: .connectionHint),
            "Dish could decode it: a connection problem"
        )
        XCTAssertEqual(scheduler.liveTimers.count, 0, "the tick stops with the last check")
    }

    func testACheckOnAPadDishCannotDecodeOffersHelpSupportingIt() throws {
        _ = paths.gameControllerAttached(id: "gc:pad", name: "Pad", category: "MFi", hasRumble: false) // The gate is not under test.
        paths.startCheck(slotId: "gc:pad")
        clock.nowMs += InputCheckWindow.durationMs
        try XCTUnwrap(scheduler.liveTimers.first).fire()
        XCTAssertEqual(paths.state["gc:pad"]?.check, .concluded(.noDecoder, offer: .helpSupport))
    }

    func testAGameControllerPadIsStandardAndItsHandlersProveIt() {
        let gate = paths.gameControllerAttached(id: "gc:pad", name: "Pad", category: "MFi", hasRumble: true)
        XCTAssertEqual(gate.routed, .standard)
        XCTAssertEqual(paths.state["gc:pad"]?.reason, .macOSReads)
        XCTAssertEqual(paths.state["gc:pad"]?.rumble, .ownController)
        XCTAssertTrue(gate.pass(.standard, changed: true))
        spinMainUntil { paths.state["gc:pad"]?.proven == true }
        XCTAssertEqual(paths.state["gc:pad"]?.proven, true)
        XCTAssertEqual(records.first, InputPathRecord(subject: "Pad", note: .chosen(.standard, .macOSReads)))
    }

    // MARK: - Picks

    func testAPickIsRefusedWhereThePathIsNotAvailable() throws {
        try arrive(productId: 0x2019, slotId: Self.n64)
        _ = paths.gameControllerAttached(id: "gc:pad", name: "Pad", category: "MFi", hasRumble: false) // The gate is not under test.
        XCTAssertFalse(paths.pick(slotId: Self.n64, .standard), "never Standard for the N64")
        XCTAssertFalse(paths.pick(slotId: Self.n64, .direct), "already Direct")
        XCTAssertFalse(paths.pick(slotId: "gc:pad", .direct), "Dish has no decoder for it")
        XCTAssertFalse(paths.pick(slotId: "nobody", .direct))
        XCTAssertNil(storedChoices())
        XCTAssertEqual(paths.state[Self.n64]?.source, .direct)
    }

    func testPickingStandardForAProHandsItToItsCarrierAndIsRemembered() throws {
        let carrierGate = attachProCarrier()
        try arrive(productId: 0x2009, slotId: Self.pro)
        XCTAssertEqual(host.carriersShown[Self.proCarrier], false, "R7: no input slot of its own")
        XCTAssertNil(carrierGate.routed)
        XCTAssertEqual(host.outputCarriers[Self.pro], Self.proCarrier, "one carrier, one pad: GameController carries its output")
        let slot = try XCTUnwrap(host.directSlots[Self.pro])
        XCTAssertTrue(slot.capabilities.hasRumble)
        XCTAssertTrue(slot.capabilities.hasPlayerLeds)
        XCTAssertTrue(slot.capabilities.hasMotion, "the Pro's IMU")
        XCTAssertEqual(paths.state[Self.pro]?.picks, [.standard])
        XCTAssertEqual(paths.state[Self.pro]?.rumble, .carried)

        XCTAssertTrue(paths.pick(slotId: Self.pro, .standard))
        XCTAssertNil(host.directSlots[Self.pro])
        XCTAssertEqual(host.carriersShown[Self.proCarrier], true)
        XCTAssertEqual(carrierGate.routed, .standard)
        XCTAssertEqual(storedChoices(), ["057e:2009": "standard"])
        let carried = try XCTUnwrap(paths.state[Self.proCarrier])
        XCTAssertEqual(carried.source, .standard)
        XCTAssertEqual(carried.reason, .userPicked)
        XCTAssertEqual(carried.picks, [.direct])
        XCTAssertNil(paths.state[Self.pro], "the Direct slot is gone while the carrier reads it")

        XCTAssertTrue(paths.pick(slotId: Self.proCarrier, .direct), "the carrier's slot picks for its pad")
        XCTAssertNotNil(host.directSlots[Self.pro])
        XCTAssertEqual(host.carriersShown[Self.proCarrier], false)
        XCTAssertEqual(storedChoices(), ["057e:2009": "direct"])
    }

    func testAStoredStandardWaitsForGameControllerThenShowsTheCarrier() throws {
        UsbPathChoiceStore(defaults: defaults).setChoice(.standard, vendorId: 0x057E, productId: 0x2009)
        paths = makePaths()
        attachProCarrier()
        try arrive(productId: 0x2009, slotId: Self.pro, support: [false, true])
        XCTAssertNil(host.directSlots[Self.pro], "waiting on GameController's answer")
        XCTAssertEqual(host.carriersShown[Self.proCarrier], false)
        scheduler.advance(ms: 10)
        XCTAssertEqual(host.carriersShown[Self.proCarrier], true)
        XCTAssertEqual(paths.state[Self.proCarrier]?.reason, .userPicked)
        XCTAssertNil(host.directSlots[Self.pro])
    }

    func testACarrierHearsForItsPadDuringACheck() throws {
        let carrierGate = attachProCarrier()
        try arrive(productId: 0x2009, slotId: Self.pro)
        paths.startCheck(slotId: Self.pro)
        XCTAssertTrue(carrierGate.awaitsEvent(.standard))
        XCTAssertFalse(carrierGate.pass(.standard, changed: true), "heard, never published")
        drainMain()
        clock.nowMs += InputCheckWindow.durationMs
        try XCTUnwrap(scheduler.liveTimers.first).fire()
        XCTAssertEqual(paths.state[Self.pro]?.check, .concluded(.standardWorks, offer: CheckOffer.none))
    }

    // MARK: - Output carriage

    func testTwoIdenticalProsMakeTheirRumbleAmbiguous() throws {
        attachProCarrier()
        try arrive(productId: 0x2009, slotId: Self.pro)
        try arrive(productId: 0x2009, slotId: "\(Self.pro)#1")
        XCTAssertEqual(paths.state[Self.pro]?.rumble, .ambiguous)
        XCTAssertNil(host.outputCarriers[Self.pro])
        XCTAssertEqual(host.directSlots[Self.pro]?.capabilities.hasRumble, false)
    }

    // MARK: - Drops, players and rates

    func testThreeDropsWithinAMinuteRaiseOneNotice() throws {
        for _ in 0 ..< 3 {
            try arrive(productId: 0x2019, slotId: Self.n64)
            paths.hidPadRemoved(slotId: Self.n64)
            clock.nowMs += 10000
        }
        XCTAssertEqual(records.filter { $0.note == .keepsDisconnecting }.count, 1)
        try arrive(productId: 0x2019, slotId: Self.n64)
        XCTAssertEqual(paths.state[Self.n64]?.keepsDisconnecting, true)
    }

    func testARemovedPadLosesItsSlotAndItsFacts() throws {
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        paths.hidPadRemoved(slotId: Self.n64)
        XCTAssertNil(host.directSlots[Self.n64])
        XCTAssertNil(paths.state[Self.n64])
        XCTAssertNil(arrival.lane.gate.routed, "nothing more is published")
    }

    func testPlayerNumbersFollowTheSlotListByConnectionOrder() {
        _ = paths.gameControllerAttached(id: "gc:a", name: "A", category: "MFi", hasRumble: false) // The gate is not under test.
        _ = paths.gameControllerAttached(id: "gc:b", name: "B", category: "MFi", hasRumble: false) // The gate is not under test.
        paths.slotsChanged(["gc:a", "gc:b"])
        XCTAssertEqual(paths.state["gc:a"]?.playerNumber, 1)
        XCTAssertEqual(paths.state["gc:b"]?.playerNumber, 2)
        paths.slotsChanged(["gc:b"])
        _ = paths.gameControllerAttached(id: "gc:c", name: "C", category: "MFi", hasRumble: false) // The gate is not under test.
        paths.slotsChanged(["gc:b", "gc:c"])
        XCTAssertEqual(paths.state["gc:b"]?.playerNumber, 2, "a pad keeps its number")
        XCTAssertEqual(paths.state["gc:c"]?.playerNumber, 1, "the next pad takes the lowest free one")
    }

    func testTheRawRateIsTheLanesCountOverATick() throws {
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        paths.sampleRawRates(nowUs: 0)
        for _ in 0 ..< 83 {
            feedReport(DirectFixtures.n64Idle, to: arrival.lane)
        }
        paths.sampleRawRates(nowUs: 1_000_000)
        XCTAssertEqual(paths.state[Self.n64]?.rawReportHz, 85, "83 reports in a second, in the inspector's 5 Hz steps")
    }

    func testADetachedCarrierTakesTheOutputWithIt() throws {
        attachProCarrier()
        try arrive(productId: 0x2009, slotId: Self.pro)
        paths.gameControllerDetached(id: Self.proCarrier, name: "Nintendo")
        XCTAssertNil(host.outputCarriers[Self.pro])
        XCTAssertEqual(paths.state[Self.pro]?.rumble, .noCarrier)
        XCTAssertTrue(paths.showsInputSlot("gc:anything-else"), "a controller that is no carrier always shows")
    }
}
