// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// `dish-diagnostics.v1`: the contract's shape from the facts the pages
/// render, and nothing a person would not want mailed.
final class DiagnosticsBundleTests: XCTestCase {

    /// Values that must never reach the file, planted where they could leak.
    private enum Forbidden {
        static let hostName = "Emir's Gaming PC"
        static let address = "192.168.1.44"
        static let otherHost = "living-room.local"
    }

    /// A DualSense on USB as IOKit and the registry describe it.
    private static func dualSenseHardware() -> BundleHardwareFacts {
        var hardware = BundleHardwareFacts(vendorId: 0x054C, productId: 0x0CE6, product: "Wireless Controller", manufacturer: "Sony")
        hardware.bcdDevice = 0x0107
        hardware.interfaces = [
            BundleUsbInterface(number: 0, interfaceClass: 0x01, subclass: 0x01, interfaceProtocol: 0x00),
            BundleUsbInterface(number: 3, interfaceClass: 0x03, subclass: 0x00, interfaceProtocol: 0x00)
        ]
        hardware.endpoints = BundleEndpoints(input: 0x84, output: 0x03)
        hardware.descriptorSha256 = descriptorSha256
        return hardware
    }

    private func fixture() -> DiagnosticsBundleFacts {
        let record = ControllerRecord(id: "sony-dualsense", familyId: "dualsense", verification: .verified)
        let pad = BundlePadFacts(
            record: record,
            transport: .usb,
            path: .direct,
            hardware: Self.dualSenseHardware(),
            expectMismatches: ["endpoints.out: expected true, found false"],
            lastWrite: DirectWriteVerdict(route: .setReport, reportId: 2, status: Int32(bitPattern: 0xE000_02ED), atMs: 1_763_586_000_100),
            outcomes: [TestOutcome(test: .rumbleStrong, result: .worked, atMs: 1_763_585_990_000)],
            capture: "VID:PID 054c:0ce6",
            input: BundlePadInput(frames: 1000, rateHz: 250, last: nil),
            audio: BundleAudio(channels: 4, refused: false)
        )
        let hosts = [
            BundleHostFacts(
                names: [Forbidden.hostName, Forbidden.address],
                kind: .satellite,
                version: "2.3.0",
                protocolVersion: 4,
                link: "live",
                grants: HostAudioVerdict(mic: false, speaker: true, hapticAudio: false)
            ),
            BundleHostFacts(names: [Forbidden.otherHost], kind: .moonlight, version: nil, protocolVersion: nil, link: "saved", grants: nil)
        ]
        let log = [
            BundleLogFacts(atMs: 1, tag: "linkChanged", message: "\(Forbidden.hostName): linking -> live"),
            BundleLogFacts(atMs: 2, tag: "padBound", message: "DualSense -> \(Forbidden.address)"),
            BundleLogFacts(atMs: 3, tag: "linkAppeared", message: "\(Forbidden.otherHost): saved")
        ]
        return DiagnosticsBundleFacts(
            createdAtMs: 1_763_586_251_000,
            app: BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github"),
            device: BundleDeviceFacts(model: "Mac14,2", os: "macOS 26.1", arch: "arm64"),
            controllerDb: ControllerDbStatus(
                bundledVersion: 1,
                activeVersion: 3,
                source: .cache,
                lastCheckAtMs: 1_763_582_400_000,
                lastCheckResult: .upToDate
            ),
            pads: [pad, BundlePadFacts(record: nil, transport: nil, path: .gameController, hardware: nil)],
            hosts: hosts,
            log: log
        )
    }

    private static let descriptorSha256 = "5f2c0d3c8bb7f1d36ee86c1e4b4e9a3a2e7b1f0d9c8a7b6e5d4c3b2a19087f6e"

    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(fixture())) as? [String: Any])
    }

    func testTheEnvelopeIsBundleOneWithTheAppAndTheDevice() throws {
        let bundle = try object()
        XCTAssertEqual(bundle["bundle"] as? Int, 1)
        XCTAssertEqual(bundle["createdAt"] as? String, "2025-11-19T21:04:11Z")
        XCTAssertEqual(bundle["app"] as? [String: String], ["name": "dish-mac", "version": "1.4.0", "build": "1.4.0", "flavor": "github"])
        XCTAssertEqual(bundle["device"] as? [String: String], ["model": "Mac14,2", "os": "macOS 26.1", "arch": "arm64"])
    }

    func testTheDataStatusIsCarried() throws {
        let status = try XCTUnwrap(try object()["controllerDb"] as? [String: Any])
        XCTAssertEqual(status["bundledVersion"] as? Int, 1)
        XCTAssertEqual(status["activeVersion"] as? Int, 3)
        XCTAssertEqual(status["source"] as? String, "cache")
        XCTAssertEqual(status["lastCheckAt"] as? String, "2025-11-19T20:00:00Z")
        XCTAssertEqual(status["lastCheckResult"] as? String, "upToDate")
    }

    func testAPadCarriesItsRecordHardwareMismatchesWriteOutcomesAndCapture() throws {
        let pads = try XCTUnwrap(try object()["controllers"] as? [[String: Any]])
        let pad = try XCTUnwrap(pads.first)
        XCTAssertEqual(pad["record"] as? String, "sony-dualsense")
        XCTAssertEqual(pad["verification"] as? String, "verified")
        XCTAssertEqual(pad["transport"] as? String, "usb")
        XCTAssertEqual(pad["path"] as? String, "direct")
        let hardware = try XCTUnwrap(pad["hardware"] as? [String: Any])
        XCTAssertEqual(hardware["vid"] as? String, "054c")
        XCTAssertEqual(hardware["pid"] as? String, "0ce6")
        XCTAssertEqual(hardware["product"] as? String, "Wireless Controller")
        XCTAssertEqual(hardware["manufacturer"] as? String, "Sony")
        XCTAssertEqual(pad["expectMismatch"] as? [String], ["endpoints.out: expected true, found false"])
        let write = try XCTUnwrap(pad["lastWrite"] as? [String: Any])
        XCTAssertEqual(write["route"] as? String, "setReport")
        XCTAssertEqual(write["reportId"] as? String, "02")
        XCTAssertEqual(write["ok"] as? Bool, false)
        XCTAssertEqual(write["err"] as? String, "kIOReturnNotResponding")
        let outcome = try XCTUnwrap((pad["outcomes"] as? [[String: Any]])?.first)
        XCTAssertEqual(outcome["test"] as? String, "rumble.strong")
        XCTAssertEqual(outcome["result"] as? String, "worked")
        XCTAssertEqual(pad["capture"] as? [String: String], ["format": "support-capture-text", "text": "VID:PID 054c:0ce6"])
    }

    func testAPadWithNoRecordOrCaptureSaysNullForBoth() throws {
        let pads = try XCTUnwrap(try object()["controllers"] as? [[String: Any]])
        let bare = try XCTUnwrap(pads.last)
        XCTAssertTrue(bare["record"] is NSNull)
        XCTAssertTrue(bare["capture"] is NSNull)
        XCTAssertEqual(bare["path"] as? String, "gameController")
        XCTAssertNil(bare["hardware"])
    }

    func testThePadsHardwareCarriesItsVersionInterfacesEndpointsAndDescriptorFingerprint() throws {
        let pad = try XCTUnwrap(try (object()["controllers"] as? [[String: Any]])?.first)
        let hardware = try XCTUnwrap(pad["hardware"] as? [String: Any])
        XCTAssertEqual(hardware["bcdDevice"] as? String, "0107", "four hex digits, as vid and pid")
        XCTAssertEqual(hardware["interfaces"] as? [[String: AnyHashable]], [
            ["number": 0, "class": "01", "subclass": "01", "protocol": "00"],
            ["number": 3, "class": "03", "subclass": "00", "protocol": "00"]
        ])
        XCTAssertEqual(hardware["endpoints"] as? [String: String], ["in": "84", "out": "03"])
        XCTAssertEqual(hardware["descriptorSha256"] as? String, Self.descriptorSha256)
        XCTAssertTrue(hardware["firmware"] is NSNull, "IOKit names no firmware for a pad")
    }

    func testHardwareIOKitDidNotGiveIsNull() throws {
        let facts = DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: fixture().app,
            device: fixture().device,
            controllerDb: ControllerDbStatus(),
            pads: [BundlePadFacts(
                record: nil,
                transport: .bluetooth,
                path: .gameController,
                hardware: BundleHardwareFacts(vendorId: 0x045E, productId: 0x0B13, product: nil, manufacturer: nil)
            )],
            hosts: [],
            log: []
        )
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
        let hardware = try XCTUnwrap(((file["controllers"] as? [[String: Any]])?.first)?["hardware"] as? [String: Any])
        for key in ["bcdDevice", "product", "manufacturer", "interfaces", "endpoints", "descriptorSha256", "firmware"] {
            XCTAssertTrue(hardware[key] is NSNull, key)
        }
    }

    func testAnOutPipeTheInterfaceLacksIsNull() throws {
        var hardware = BundleHardwareFacts(vendorId: 0x2DC8, productId: 0x310B, product: nil, manufacturer: nil)
        hardware.endpoints = BundleEndpoints(input: 0x81, output: nil)
        let facts = DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: fixture().app,
            device: fixture().device,
            controllerDb: ControllerDbStatus(),
            pads: [BundlePadFacts(record: nil, transport: .usb, path: .direct, hardware: hardware)],
            hosts: [],
            log: []
        )
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
        let hardwareFile = try XCTUnwrap(((file["controllers"] as? [[String: Any]])?.first)?["hardware"] as? [String: Any])
        let endpoints = try XCTUnwrap(hardwareFile["endpoints"] as? [String: Any])
        XCTAssertEqual(endpoints["in"] as? String, "81")
        XCTAssertTrue(endpoints["out"] is NSNull)
    }

    func testThePadCarriesItsRateItsAudioFunctionAndNoProbe() throws {
        let pad = try XCTUnwrap(try (object()["controllers"] as? [[String: Any]])?.first)
        XCTAssertEqual(pad["rateHz"] as? Int, 250, "the rate the reports the app counts measured")
        XCTAssertEqual(pad["audio"] as? [String: AnyHashable], ["channels": 4, "refused": false])
        XCTAssertTrue(pad["probe"] is NSNull, "the Mac's gate is GameController's answer, not a decode probe")
    }

    func testAPadWithNoFeedOrAudioFunctionSaysNullForBoth() throws {
        let bare = try XCTUnwrap(try (object()["controllers"] as? [[String: Any]])?.last)
        XCTAssertTrue(bare["rateHz"] is NSNull)
        XCTAssertTrue(bare["audio"] is NSNull)
    }

    func testHostsAreAliasesInOrderWithWhatTheyAreButNotWhoTheyAre() throws {
        let hosts = try XCTUnwrap(try object()["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.map { $0["alias"] as? String }, ["Host 1", "Host 2"])
        XCTAssertEqual(hosts.first?["kind"] as? String, "satellite")
        XCTAssertEqual(hosts.first?["version"] as? String, "2.3.0")
        XCTAssertEqual(hosts.first?["protocol"] as? Int, 4)
        XCTAssertEqual(hosts.first?["link"] as? String, "live")
        XCTAssertEqual(hosts.first?["grants"] as? [String: Bool], ["mic": false, "speaker": true, "hapticAudio": false])
    }

    func testTheLogNamesHostsByTheirAliases() throws {
        let log = try XCTUnwrap(try object()["log"] as? [[String: Any]])
        XCTAssertEqual(log.map { $0["message"] as? String }, ["Host 1: linking -> live", "DualSense -> Host 1", "Host 2: saved"])
        XCTAssertEqual(log.first?["tag"] as? String, "linkChanged")
    }

    func testNoForbiddenValueReachesTheFile() throws {
        let text = try XCTUnwrap(String(data: diagnosticsBundleJSON(fixture()), encoding: .utf8))
        for forbidden in [Forbidden.hostName, Forbidden.address, Forbidden.otherHost] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testANameThatContainsAnotherIsReplacedWhole() throws {
        let hosts = [
            BundleHostFacts(names: ["PC"], kind: .satellite, version: nil, protocolVersion: nil, link: "live", grants: nil),
            BundleHostFacts(names: ["Gaming PC"], kind: .satellite, version: nil, protocolVersion: nil, link: "live", grants: nil)
        ]
        let base = fixture()
        let facts = DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: base.app,
            device: base.device,
            controllerDb: base.controllerDb,
            pads: [],
            hosts: hosts,
            log: [BundleLogFacts(atMs: 0, tag: "t", message: "Gaming PC and PC")]
        )
        let log =
            try XCTUnwrap((JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])?["log"] as? [[String: Any]])
        XCTAssertEqual(log.first?["message"] as? String, "Host 2 and Host 1")
    }

    func testTheAttachmentIsNamedForTheAppAndTheMomentInUTC() {
        XCTAssertEqual(
            diagnosticsBundleFileName(app: "dish-mac", atMs: 1_763_586_251_000),
            "dish-diagnostics-dish-mac-20251119-210411.json"
        )
    }

    func testTheRecipientIsSupport() {
        XCTAssertEqual(DiagnosticsBundleFormat.recipient, "support@tinkernorth.com")
        XCTAssertEqual(hostAlias(0), "Host 1")
    }
}
