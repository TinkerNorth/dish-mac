// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The bundle's facts from what Diagnostics renders: each pad's record, path,
/// hardware, write and answers, the hosts as aliases, and no host's name,
/// address or hostname anywhere in the file.
final class DiagnosticsBundleFactsTests: XCTestCase {

    private enum Forbidden {
        static let satelliteName = "Emir's Gaming PC"
        static let satelliteAddress = "192.168.1.44"
        static let moonlightName = "Den Sunshine"
        static let moonlightAddress = "10.0.0.7"
        static let moonlightHostname = "den-pc.local"
        static let forgottenHost = "Old Laptop"
    }

    private let dualsense = ControllerRecord(id: "sony-dualsense", usb: ["054c:0ce6"], familyId: "dualsense", verification: .verified)

    private func directPad() -> PadDiagnostics {
        let bound = ConnectionSummary(
            id: "sat",
            name: Forbidden.satelliteName,
            address: Forbidden.satelliteAddress,
            live: .connected,
            boundSlotId: "pad"
        )
        var path = SlotInputPath(source: .direct, reason: .macOSReads)
        path.expectMismatches = ["endpoints.out: expected true, found false"]
        path.lastWrite = DirectWriteVerdict(route: .setReport, reportId: 2, status: 0, atMs: 5)
        var pad = PadDiagnostics(
            slot: ControllerSlot(id: "pad", name: "DualSense Wireless Controller", boundConnectionId: "sat", boundStatus: bound),
            wire: nil,
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6),
            inputPath: path
        )
        var device = HidDeviceFacts(
            id: 1,
            name: "Wireless Controller",
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6),
            transport: .usb,
            claimedByGameController: true
        )
        device.manufacturer = "Sony Interactive Entertainment"
        pad.device = device
        pad.record = dualsense
        pad.transport = .usb
        return pad
    }

    private func inputs(capture: FinishedCapture? = nil) -> DiagnosticsBundleInputs {
        let satellite = HostDiagnostics(
            summary: ConnectionSummary(
                id: "sat",
                name: Forbidden.satelliteName,
                address: Forbidden.satelliteAddress,
                live: .connected,
                boundSlotId: "pad"
            ),
            facts: HostSessionFacts.resting(id: "sat")
        )
        let xml = "<root status_code=\"200\"><hostname>\(Forbidden.moonlightHostname)</hostname><appversion>7.1.431</appversion></root>"
        let info = MoonlightXml.serverInfo(xml)
        let moonlight = HostDiagnostics(
            summary: ConnectionSummary(
                id: "ml",
                name: Forbidden.moonlightName,
                address: Forbidden.moonlightAddress,
                live: .saved,
                boundSlotId: nil,
                kind: .moonlight
            ),
            facts: HostSessionFacts.resting(id: "ml"),
            moonlight: .resting(info: info)
        )
        let gameControllerPad = PadDiagnostics(slot: ControllerSlot(id: "gc", name: "Xbox Wireless Controller"), wire: nil)
        let events = [
            DiagnosticsEvent(atMs: 1, kind: .linkChanged, subject: Forbidden.satelliteName, from: .connecting, to: .connected),
            DiagnosticsEvent(atMs: 2, kind: .padBound, subject: "DualSense Wireless Controller", host: Forbidden.satelliteAddress),
            DiagnosticsEvent(atMs: 3, kind: .linkRemoved, subject: Forbidden.forgottenHost, to: .saved),
            DiagnosticsEvent(atMs: 4, kind: .padUnbound, subject: "Pad", host: Forbidden.forgottenHost),
            DiagnosticsEvent(atMs: 5, kind: .padAttached, subject: "Pad")
        ]
        let outcomes = PadOutcomes(answers: ["pad": [TestOutcome(test: .rumbleStrong, result: .worked, atMs: 9)]])
        return DiagnosticsBundleInputs(
            createdAtMs: 1_763_586_251_000,
            app: BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github"),
            machine: HostMachine(model: "Mac14,2", osMajor: 26, osMinor: 1, arch: "arm64"),
            snapshot: DiagnosticsSnapshot(hosts: [satellite, moonlight], pads: [directPad(), gameControllerPad]),
            events: events,
            outcomes: outcomes,
            capture: capture,
            hostVersions: ["sat": "2.3.0"]
        )
    }

    func testADirectPadCarriesItsRecordHardwareMismatchesWriteAndAnswers() throws {
        let pad = try XCTUnwrap(diagnosticsBundleFacts(inputs()).pads.first)
        XCTAssertEqual(pad.record?.id, "sony-dualsense")
        XCTAssertEqual(pad.path, .direct)
        XCTAssertEqual(pad.transport, .usb)
        XCTAssertEqual(
            pad.hardware,
            BundleHardwareFacts(
                vendorId: 0x054C,
                productId: 0x0CE6,
                product: "Wireless Controller",
                manufacturer: "Sony Interactive Entertainment"
            )
        )
        XCTAssertEqual(pad.expectMismatches, ["endpoints.out: expected true, found false"])
        XCTAssertEqual(pad.lastWrite?.reportId, 2)
        XCTAssertEqual(pad.outcomes.map(\.test), [.rumbleStrong])
        XCTAssertNil(pad.capture)
    }

    func testAPadGameControllerReadsIsOnThatPathWithNoHardwareItCannotName() throws {
        let pad = try XCTUnwrap(diagnosticsBundleFacts(inputs()).pads.last)
        XCTAssertEqual(pad.path, .gameController)
        XCTAssertNil(pad.hardware)
        XCTAssertNil(pad.record)
    }

    private static let taken = BundleCapture(
        device: "Transport: USB",
        product: "Pad",
        manufacturer: nil,
        interfaceNumber: 0,
        reportDescriptor: [0x05, 0x01],
        restReports: []
    )

    func testTheCaptureRidesThePadItWasTakenOfByIdentityOrByName() {
        let byIdentity = diagnosticsBundleFacts(inputs(capture: FinishedCapture(deviceKey: "054c:0ce6", report: "R", capture: Self.taken)))
        XCTAssertEqual(byIdentity.pads.map(\.capture), [Self.taken, nil])
        XCTAssertEqual(byIdentity.supportCaptureText, "R", "the guided steps ride beside it")
        let named = FinishedCapture(deviceKey: "named:Xbox Wireless Controller", report: "N", capture: Self.taken)
        let byName = diagnosticsBundleFacts(inputs(capture: named))
        XCTAssertEqual(byName.pads.map(\.capture), [nil, Self.taken])
        XCTAssertEqual(byName.supportCaptureText, "N")
    }

    func testACaptureOfNoPadInTheFileRidesNowhere() {
        let elsewhere = diagnosticsBundleFacts(inputs(capture: FinishedCapture(deviceKey: "1234:5678", report: "X", capture: Self.taken)))
        XCTAssertEqual(elsewhere.pads.map(\.capture), [nil, nil])
        XCTAssertNil(elsewhere.supportCaptureText)
    }

    func testHostsCarryWhatTheyAreAndTheirVersions() {
        let hosts = diagnosticsBundleFacts(inputs()).hosts
        XCTAssertEqual(hosts.map(\.kind), [.satellite, .moonlight])
        XCTAssertEqual(hosts.map(\.version), ["2.3.0", "7.1.431"])
        XCTAssertEqual(hosts.map(\.link), ["connected", "saved"])
        XCTAssertNil(hosts.first?.protocolVersion, "no session, no settled protocol")
        XCTAssertEqual(hosts.first?.grants, HostAudioVerdict.none)
    }

    func testALogLineNamingAHostNoLongerListedSaysAnotherHost() {
        let log = diagnosticsBundleFacts(inputs()).log
        XCTAssertEqual(log.map(\.tag), ["linkChanged", "padBound", "linkRemoved", "padUnbound", "padAttached"])
        XCTAssertEqual(log[2].message, "another host: saved")
        XCTAssertEqual(log[3].message, "Pad -> another host")
        XCTAssertEqual(log[4].message, "Pad")
    }

    func testNoHostNameAddressOrHostnameReachesTheFile() throws {
        let file = try XCTUnwrap(String(data: diagnosticsBundleJSON(diagnosticsBundleFacts(inputs())), encoding: .utf8))
        for forbidden in [
            Forbidden.satelliteName, Forbidden.satelliteAddress, Forbidden.moonlightName,
            Forbidden.moonlightAddress, Forbidden.moonlightHostname, Forbidden.forgottenHost
        ] {
            XCTAssertFalse(file.contains(forbidden), forbidden)
        }
        XCTAssertTrue(file.contains("Host 1: connecting -> connected"))
        XCTAssertTrue(file.contains("DualSense Wireless Controller -> Host 1"))
    }

    func testTheDeviceIsTheMacsModelAndMacOS() {
        let device = diagnosticsBundleFacts(inputs()).device
        XCTAssertEqual(device, BundleDeviceFacts(model: "Mac14,2", os: "macOS 26.1", arch: "arm64"))
        XCTAssertEqual(HostMachine(model: "M", osMajor: 26, osMinor: 1, osPatch: 2, arch: "arm64").osName, "macOS 26.1.2")
    }

    // MARK: - The record on the card

    private func bundledIndex() throws -> ControllerIndex {
        try ControllerIndex(XCTUnwrap(BundledControllerDb.load()), source: .bundled)
    }

    func testAPadIsMatchedToItsRecordByTheCensusDeviceAndItsTransport() throws {
        let pad = PadDiagnostics(
            slot: ControllerSlot(id: "gc", name: "DualSense"),
            wire: nil,
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6)
        )
        let device = HidDeviceFacts(
            id: 1,
            name: "DualSense",
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6),
            transport: .usb,
            claimedByGameController: true
        )
        let known = try withRecord(pad, index: bundledIndex(), devices: [device], host: IssueHost(model: "AYN Thor", osMajor: 15))
        XCTAssertEqual(known.record?.id, "sony-dualsense")
        XCTAssertEqual(known.transport, .usb)
        XCTAssertEqual(known.device, device)
    }

    func testOnlyTheIssuesThatApplyToThisMacShow() throws {
        let pad = PadDiagnostics(
            slot: ControllerSlot(id: "gc", name: "DualSense"),
            wire: nil,
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6)
        )
        let device = HidDeviceFacts(
            id: 1,
            name: "DualSense",
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6),
            transport: .usb,
            claimedByGameController: true
        )
        let mac = try withRecord(pad, index: bundledIndex(), devices: [device], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertEqual(mac.issues, [], "the Thor's issue is not this Mac's")
    }

    func testAPadWithNoIdentityHasNoRecord() throws {
        let pad = PadDiagnostics(slot: ControllerSlot(id: "gc", name: "Mystery"), wire: nil)
        let known = try withRecord(pad, index: bundledIndex(), devices: [], host: IssueHost(model: "Mac14,2", osMajor: 26))
        XCTAssertNil(known.record)
        XCTAssertNil(known.transport)
    }
}
