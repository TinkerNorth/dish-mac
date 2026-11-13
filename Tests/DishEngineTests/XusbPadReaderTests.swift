// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// The XUSB reader against a fake bus, in the paths and the bridge as the
/// app wires them: a plugged Ultimate 2 in X-input mode is a Direct slot
/// whose reports reach its feed and whose rumble reaches its OUT pipe; an
/// unplug, a failed read and a refused open each end it cleanly.
@MainActor
final class XusbPadReaderTests: XCTestCase {

    private static let slotId = "hid:2dc8:310b"
    private static let level: [UInt8] = [0x00, 0x08, 0x00, 0x80, 0x10, 0x00, 0x00, 0x00]

    private var suite: String!
    private var defaults: UserDefaults!
    private var bus: FakeXusbBus!
    private var reader: XusbPadReader!
    private var scheduler: ManualPathScheduler!
    private let published = LockedBox<[GamepadReport]>([])

    override func setUp() {
        super.setUp()
        GCController.shouldMonitorBackgroundEvents = false
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        bus = FakeXusbBus()
        reader = XusbPadReader(bus: bus, quitBoundMs: XusbFixtures.quitBoundPastAnyStallMs)
        scheduler = ManualPathScheduler()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The bridge with the reader started and the bus watching.
    private func bridge() -> GameControllerInput {
        let paths = InputPaths(choices: UsbPathChoiceStore(defaults: defaults), reader: reader, scheduler: scheduler)
        let input = GameControllerInput(
            connected: [],
            paths: paths,
            categoryOf: { _ in "MFi" },
            hostBattery: { PadBattery(level: 50, status: .discharging) }
        )
        let published = published
        input.processor.send(reports: { _, report in published.set(published.get() + [report]) })
        reader.queue.sync {}
        return input
    }

    /// The pad plugged in, heard by the paths and past GameController's answer.
    private func plug(registryId: UInt64 = 1, port: FakeXusbPort) {
        bus.plug(registryId, XusbFixtures.ultimate2(), port: port)
        drainMain()
        scheduler.advance(ms: 100)
    }

    private func unplug(registryId: UInt64 = 1) {
        bus.unplug(registryId)
        drainMain()
        reader.queue.sync {}
    }

    private func settleRumble(_ input: GameControllerInput) throws {
        input.padActuators.queue.sync {}
        input.padActuators.queue.sync {}
        let output = try XCTUnwrap(input.paths.pads[Self.slotId]?.arrival?.lane.output as? XusbOutput)
        output.drain()
    }

    // MARK: - Plug, read, rumble

    func testAPluggedPadIsADirectSlotWhoseReportsReachItsFeed() throws {
        let input = bridge()
        let port = FakeXusbPort()
        plug(port: port)
        XCTAssertEqual(input.slots.map(\.id), [Self.slotId])
        XCTAssertEqual(input.paths.state[Self.slotId]?.source, .direct)
        XCTAssertEqual(input.paths.state[Self.slotId]?.reason, .macOSCannotRead)
        let pipe = try XCTUnwrap(port.interface?.fakeInput)
        pipe.deliver(XusbFixtures.idle)
        pipe.deliver(XusbFixtures.pressedA)
        XCTAssertEqual(published.get(), [.released, GamepadReport(buttons: WireButton.faceA.bit)])
        XCTAssertEqual(pipe.reads, 3, "the next read goes out as each report lands")
    }

    func testTheHostsRumbleReachesThePadsOutPipe() throws {
        let input = bridge()
        let port = FakeXusbPort()
        plug(port: port)
        input.applyRumble(deviceId: Self.slotId, strongMagnitude: 0x8000, weakMagnitude: 0x1000, durationMs: 500)
        try settleRumble(input)
        XCTAssertEqual(port.interface?.fakeOutput.writes.first, Self.level)
    }

    func testQuittingStillsAPadsMotorsBeforeItReturns() throws {
        let input = bridge()
        let port = FakeXusbPort()
        plug(port: port)
        input.applyRumble(deviceId: Self.slotId, strongMagnitude: 0x8000, weakMagnitude: 0x1000, durationMs: 500)
        try settleRumble(input)
        input.paths.releaseClaimsNow()
        XCTAssertEqual(port.interface?.fakeOutput.writes, [Self.level, xusbRumbleStop], "the pad holds a level until it is sent another")
    }

    func testAReaderLeftToItsDefaultGivesEachPad48MsToTakeItsStopAtQuit() {
        XCTAssertEqual(XusbPadReader(bus: FakeXusbBus()).quitBoundMs, 48)
    }

    func testTheSlotRumblesByItsOwnReportWithNoExtrasMotionTouchpadOrLights() throws {
        let input = bridge()
        plug(port: FakeXusbPort())
        let capabilities = try XCTUnwrap(input.slots.first?.capabilities)
        XCTAssertTrue(capabilities.hasRumble)
        XCTAssertTrue(capabilities.hasBattery, "the Mac's, as for any pad that reports none")
        XCTAssertFalse(capabilities.hasExtendedButtons, "protocol 4's word stays empty: XUSB has no extras")
        XCTAssertFalse(capabilities.hasMotion)
        XCTAssertFalse(capabilities.hasTouchpad)
        XCTAssertFalse(capabilities.hasPlayerLeds)
        let facts = try XCTUnwrap(input.paths.facts(forSlot: Self.slotId))
        XCTAssertEqual(facts.rumble, .ownReport)
        XCTAssertEqual(facts.picks, [], "GameController never reads it, so there is no Standard to pick")
        XCTAssertEqual(facts.transport, .usb)
        XCTAssertFalse(facts.layoutGuessed)
        XCTAssertFalse(facts.remappable)
        XCTAssertFalse(facts.capturable, "the support capture reads HID reports, and this pad sends none")
    }

    func testTwoIdenticalPadsTakeTheirOwnSlots() {
        let input = bridge()
        plug(registryId: 1, port: FakeXusbPort())
        plug(registryId: 2, port: FakeXusbPort())
        XCTAssertEqual(input.slots.map(\.id).sorted(), [Self.slotId, "\(Self.slotId)#1"])
    }

    func testAnInterfaceAlreadyReadIsNotOpenedAgain() {
        let input = bridge()
        let port = FakeXusbPort()
        plug(port: port)
        plug(port: port)
        XCTAssertEqual(port.opens, 1)
        XCTAssertEqual(input.slots.map(\.id), [Self.slotId])
    }

    func testOnlyTheXusbInterfaceOfAModelInTheTableIsOpened() {
        let input = bridge()
        let headset = FakeXusbPort()
        let unknown = FakeXusbPort()
        bus.plug(1, XusbFixtures.ultimate2(interfaceProtocol: 0x03), port: headset)
        bus.plug(2, XusbFixtures.ultimate2(productId: 0x9999), port: unknown)
        drainMain()
        XCTAssertEqual(headset.opens + unknown.opens, 0)
        XCTAssertTrue(input.paths.pads.isEmpty)
    }

    // MARK: - The pad's end

    func testUnpluggingEndsThePadAndClosesItsInterface() throws {
        let input = bridge()
        let port = FakeXusbPort()
        plug(port: port)
        let pipe = try XCTUnwrap(port.interface?.fakeInput)
        pipe.deliver(XusbFixtures.idle)
        unplug()
        XCTAssertEqual(input.slots, [])
        XCTAssertNil(input.paths.pads[Self.slotId])
        XCTAssertEqual(port.interface?.closed, true)
        pipe.deliver(XusbFixtures.pressedA)
        XCTAssertEqual(published.get(), [.released], "the aborted read was the last")
        XCTAssertEqual(pipe.reads, 2, "no read after the abort")
    }

    func testAFailedReadEndsThePadAsAnUnplugWould() throws {
        let input = bridge()
        let port = FakeXusbPort()
        plug(port: port)
        try XCTUnwrap(port.interface?.fakeInput).fail(kIOReturnNotResponding)
        drainMain()
        XCTAssertEqual(input.slots, [])
        XCTAssertNil(input.paths.pads[Self.slotId])
        XCTAssertEqual(port.interface?.closed, true)
        unplug()
        XCTAssertTrue(input.paths.pads.isEmpty, "the device leaving later ends nothing twice")
    }

    func testAnOpenAnotherClientRefusesIsARefusedClaimUntilThePadLeaves() {
        let input = bridge()
        let port = FakeXusbPort(refusing: kIOReturnExclusiveAccess)
        plug(port: port)
        XCTAssertEqual(port.opens, 1)
        XCTAssertNotNil(input.paths.pads[Self.slotId], "the paths know the pad is there")
        XCTAssertEqual(input.paths.refusals[Self.slotId], .busy)
        XCTAssertEqual(input.slots, [])
        XCTAssertNil(input.paths.facts(forSlot: Self.slotId))
        unplug()
        XCTAssertNil(input.paths.pads[Self.slotId])
        XCTAssertNil(input.paths.refusals[Self.slotId])
    }

    func testAPipeThatRefusesItsFirstReadIsARefusedClaimAndItsInterfaceIsGivenBack() {
        let input = bridge()
        let port = FakeXusbPort(refusingReads: true)
        plug(port: port)
        XCTAssertEqual(input.paths.refusals[Self.slotId], .busy)
        XCTAssertEqual(port.interface?.closed, true)
        XCTAssertEqual(input.slots, [])
    }

    // MARK: - Which interface is a pad

    func testTheUltimate2sXusbInterfaceIsACandidateOfItsModel() throws {
        let candidate = try XCTUnwrap(xusbPadCandidate(XusbFixtures.ultimate2()))
        XCTAssertEqual(candidate.model, directModel(vendorId: 0x2DC8, productId: 0x310B))
        XCTAssertEqual(candidate.decoder, .xusb)
        XCTAssertEqual(candidate.transport, .usb)
        XCTAssertEqual(candidate.family, .other)
        XCTAssertEqual(candidate.name, "8BitDo Ultimate 2 Wireless Controller")
        XCTAssertFalse(candidate.layoutGuessed)
        XCTAssertEqual(laneKindWord(candidate.decoder), "xusb", "the DEVCAPS word")
    }

    func testAnInterfaceThatIsNotAnXusbPadOfTheTableIsNoCandidate() {
        XCTAssertNil(xusbPadCandidate(XusbFixtures.ultimate2(interfaceProtocol: 0x03)), "the headset interface")
        XCTAssertNil(xusbPadCandidate(XusbFixtures.ultimate2(productId: 0x9999)), "an XUSB pad the table does not name")
        XCTAssertNil(xusbPadCandidate(XusbFixtures.ultimate2(productId: 0x3100)), "a model the table reads through HID")
        XCTAssertNil(xusbPadCandidate([:]))
    }

    func testGameControllerNeverListsAnXusbPad() {
        XCTAssertFalse(GameControllerProbe.neverListed.supports())
    }

    // MARK: - The bus

    func testOnlyADeviceWithNoConfigurationSelectedIsConfigured() {
        XCTAssertTrue(usbDeviceNeedsConfiguration(currentConfiguration: nil), "a vendor-class device arrives unconfigured")
        XCTAssertTrue(usbDeviceNeedsConfiguration(currentConfiguration: 0))
        XCTAssertFalse(usbDeviceNeedsConfiguration(currentConfiguration: 1), "a configuration someone selected stays")
    }

    func testTheDevicesWatchedForConfiguringAreTheXusbModelsByIdentity() {
        XCTAssertEqual(xusbDeviceIdentities(), [[UsbInterfaceKey.vendorId: 0x2DC8, UsbInterfaceKey.productId: 0x310B]])
    }
}
