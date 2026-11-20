// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// What the file says of a pad's link, hardware and audio function: the
/// Direct interface's own, else what the devices matched to a GameController
/// pad by name agree on, and the function Core Audio routes to it.
final class PadHardwareFactsTests: XCTestCase {

    private func bundledIndex() throws -> ControllerIndex {
        try ControllerIndex(XCTUnwrap(BundledControllerDb.load()), source: .bundled)
    }

    /// A Direct DualSense on USB whose path names no link.
    private func usbDirectPad() -> PadDiagnostics {
        let ids = HidHardwareId(vendorId: 0x054C, productId: 0x0CE6)
        var path = SlotInputPath(source: .direct, reason: .macOSReads)
        path.transport = .usb
        path.hardwareId = ids
        return PadDiagnostics(
            slot: ControllerSlot(id: "pad", name: "DualSense Wireless Controller"),
            wire: nil,
            hardwareId: ids,
            inputPath: path
        )
    }

    func testAGameControllerPadTakesTheBluetoothLinkOfTheDeviceItIsMatchedTo() throws {
        let ids = HidHardwareId(vendorId: 0x045E, productId: 0x0B13)
        let pad = PadDiagnostics(slot: ControllerSlot(id: "gc", name: "Xbox Wireless Controller"), wire: nil, hardwareId: ids)
        let device = HidDeviceFacts(
            id: 1,
            name: "Xbox Wireless Controller",
            hardwareId: ids,
            transport: .bluetooth(.le),
            claimedByGameController: true
        )
        let known = try withRecord(pad, index: bundledIndex(), devices: [device], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertEqual(known.hidTransport, .bluetooth(.le))
        XCTAssertEqual(known.transport, .bluetooth)
        XCTAssertEqual(bundlePadFacts(known, outcomes: PadOutcomes(answers: [:]), capture: nil).bluetoothLayer, .le)
    }

    func testADirectPadTakesTheLinkOfTheInterfaceItReads() throws {
        var path = SlotInputPath(source: .direct, reason: .macOSCannotRead)
        path.transport = .bluetooth(.classic)
        path.hardwareId = HidHardwareId(vendorId: 0x28DE, productId: 0x1106)
        let pad = PadDiagnostics(
            slot: ControllerSlot(id: "hid:28de:1106", name: "Steam"),
            wire: nil,
            hardwareId: path.hardwareId,
            inputPath: path
        )
        let known = try withRecord(pad, index: bundledIndex(), devices: [], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertEqual(known.hidTransport, .bluetooth(.classic))
        XCTAssertEqual(bundlePadFacts(known, outcomes: PadOutcomes(answers: [:]), capture: nil).bluetoothLayer, .classic)
    }

    func testAPadOffBluetoothHasNoLink() throws {
        let known = try withRecord(usbDirectPad(), index: bundledIndex(), devices: [], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertNil(bundlePadFacts(known, outcomes: PadOutcomes(answers: [:]), capture: nil).bluetoothLayer)
    }

    // MARK: - What IOKit said of the hardware

    private static let detail = HidHardwareDetail(
        versionNumber: 0x0107,
        descriptorSha256: String(repeating: "ab", count: 32),
        interfaces: [BundleUsbInterface(number: 3, interfaceClass: 0x03, subclass: 0x00, interfaceProtocol: 0x00)],
        endpoints: nil
    )

    func testADirectPadsHardwareIsWhatIOKitSaidOfTheInterfaceItReads() throws {
        var pad = usbDirectPad()
        var path = try XCTUnwrap(pad.inputPath)
        path.hardware = Self.detail
        pad = PadDiagnostics(slot: pad.slot, wire: nil, hardwareId: pad.hardwareId, inputPath: path)
        let known = try withRecord(pad, index: bundledIndex(), devices: [], host: IssueHost(model: "Mac14,2", osMajor: 26))
        let hardware = try XCTUnwrap(bundlePadFacts(known, outcomes: PadOutcomes(answers: [:]), capture: nil).hardware)
        XCTAssertEqual(hardware.bcdDevice, 0x0107)
        XCTAssertEqual(hardware.descriptorSha256, Self.detail.descriptorSha256)
        XCTAssertEqual(hardware.interfaces, Self.detail.interfaces)
        XCTAssertNil(hardware.endpoints)
    }

    func testAGameControllerPadTakesTheHardwareOfTheDevicesMatchedToIt() throws {
        let ids = HidHardwareId(vendorId: 0x054C, productId: 0x0CE6)
        let pad = PadDiagnostics(slot: ControllerSlot(id: "gc", name: "DualSense"), wire: nil, hardwareId: ids)
        var device = HidDeviceFacts(id: 1, name: "DualSense", hardwareId: ids, transport: .usb, claimedByGameController: true)
        device.detail = Self.detail
        let known = try withRecord(pad, index: bundledIndex(), devices: [device], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertEqual(known.hardwareDetail, Self.detail)
        XCTAssertEqual(bundlePadFacts(known, outcomes: PadOutcomes(answers: [:]), capture: nil).hardware?.bcdDevice, 0x0107)
    }

    func testTwinsWhoseHardwareDiffersSayNothingOfIt() throws {
        let ids = HidHardwareId(vendorId: 0x054C, productId: 0x0CE6)
        let pad = PadDiagnostics(slot: ControllerSlot(id: "gc", name: "DualSense"), wire: nil, hardwareId: ids)
        var wired = HidDeviceFacts(id: 1, name: "DualSense", hardwareId: ids, transport: .usb, claimedByGameController: true)
        wired.detail = Self.detail
        let wireless = HidDeviceFacts(
            id: 2,
            name: "DualSense",
            hardwareId: ids,
            transport: .bluetooth(.classic),
            claimedByGameController: true
        )
        let known = try withRecord(pad, index: bundledIndex(), devices: [wired, wireless], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertNil(known.hardwareDetail, "which twin is the pad is unknown")
        let hardware = try XCTUnwrap(bundlePadFacts(known, outcomes: PadOutcomes(answers: [:]), capture: nil).hardware)
        XCTAssertNil(hardware.bcdDevice)
        XCTAssertNil(hardware.descriptorSha256)
    }

    func testThePadsAudioFunctionRidesWithItsChannelsAndWhetherMacOSRefusedIt() {
        let device = AudioDeviceFacts(
            id: 7,
            uid: "uid",
            name: "DualSense Wireless Controller",
            isUSB: true,
            inputChannels: 2,
            outputChannels: 4
        )
        let route = PadAudioRoute(verdict: .routed, function: PadAudioFunction(device: device, family: .dualSense))
        var state = ControllerAudioState()
        state.playbackRefused = true
        let routed = PadDiagnostics(
            slot: ControllerSlot(id: "gc", name: "DualSense"),
            wire: nil,
            audio: PadAudioDiagnostics(route: route, state: state, counters: nil)
        )
        XCTAssertEqual(
            bundlePadFacts(routed, outcomes: PadOutcomes(answers: [:]), capture: nil).audio,
            BundleAudio(channels: 4, refused: true)
        )
        let open = PadDiagnostics(
            slot: routed.slot,
            wire: nil,
            audio: PadAudioDiagnostics(route: route, state: ControllerAudioState(), counters: nil)
        )
        XCTAssertEqual(
            bundlePadFacts(open, outcomes: PadOutcomes(answers: [:]), capture: nil).audio,
            BundleAudio(channels: 4, refused: false)
        )
    }

    func testAPadWithNoAudioFunctionRoutedHasNoAudioBlock() {
        let unrouted = PadDiagnostics(
            slot: ControllerSlot(id: "gc", name: "DualSense"),
            wire: nil,
            audio: PadAudioDiagnostics(route: PadAudioRoute(verdict: .noAudioFunction, function: nil), state: nil, counters: nil)
        )
        XCTAssertNil(bundlePadFacts(unrouted, outcomes: PadOutcomes(answers: [:]), capture: nil).audio)
        XCTAssertNil(bundlePadFacts(PadDiagnostics(slot: unrouted.slot, wire: nil), outcomes: PadOutcomes(answers: [:]), capture: nil)
            .audio)
    }

    func testTheSecondCutsReadingKeepsTheLinkAndTheAudioFunction() throws {
        let device = AudioDeviceFacts(
            id: 7,
            uid: "uid",
            name: "DualSense Wireless Controller",
            isUSB: true,
            inputChannels: 2,
            outputChannels: 4
        )
        let route = PadAudioRoute(verdict: .routed, function: PadAudioFunction(device: device, family: .dualSense))
        var pad = PadDiagnostics(
            slot: ControllerSlot(id: "gc", name: "DualSense"),
            wire: nil,
            audio: PadAudioDiagnostics(route: route, state: nil, counters: nil)
        )
        pad.hidTransport = .bluetooth(.le)
        let asked = DiagnosticsBundleInputs(
            createdAtMs: 0,
            app: BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github"),
            machine: HostMachine(model: "Mac14,2", osMajor: 26, osMinor: 1, arch: "arm64"),
            snapshot: DiagnosticsSnapshot(pads: [pad]),
            events: [],
            outcomes: PadOutcomes(answers: [:]),
            capture: nil,
            hostVersions: [:]
        )
        let facts = try XCTUnwrap(diagnosticsBundleFacts(asked).pads.first)
        XCTAssertEqual(facts.bluetoothLayer, .le)
        XCTAssertEqual(facts.audio, BundleAudio(channels: 4, refused: false))
    }
}
