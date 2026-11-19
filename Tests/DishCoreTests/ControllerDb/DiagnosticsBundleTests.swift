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

    private func fixture() -> DiagnosticsBundleFacts {
        let record = ControllerRecord(id: "sony-dualsense", familyId: "dualsense", verification: .verified)
        let pad = BundlePadFacts(
            record: record,
            transport: .usb,
            path: .direct,
            hardware: BundleHardwareFacts(vendorId: 0x054C, productId: 0x0CE6, product: "Wireless Controller", manufacturer: "Sony"),
            expectMismatches: ["endpoints.out: expected true, found false"],
            lastWrite: DirectWriteVerdict(route: .setReport, reportId: 2, status: Int32(bitPattern: 0xE000_02ED), atMs: 1_763_586_000_100),
            outcomes: [TestOutcome(test: .rumbleStrong, result: .worked, atMs: 1_763_585_990_000)],
            capture: "VID:PID 054c:0ce6"
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
        XCTAssertEqual(
            pad["hardware"] as? [String: String],
            ["vid": "054c", "pid": "0ce6", "product": "Wireless Controller", "manufacturer": "Sony"]
        )
        XCTAssertEqual(pad["expectMismatch"] as? [String], ["endpoints.out: expected true, found false"])
        let write = try XCTUnwrap(pad["lastWrite"] as? [String: Any])
        XCTAssertEqual(write["route"] as? String, "setReport")
        XCTAssertEqual(write["reportId"] as? String, "02")
        XCTAssertEqual(write["ok"] as? Bool, false)
        XCTAssertEqual(write["err"] as? String, "kIOReturnNotResponding")
        let outcome = try XCTUnwrap((pad["outcomes"] as? [[String: Any]])?.first)
        XCTAssertEqual(outcome["test"] as? String, "rumble.strong")
        XCTAssertEqual(outcome["result"] as? String, "worked")
        XCTAssertEqual(pad["capture"] as? String, "VID:PID 054c:0ce6")
    }

    func testAPadWithNoRecordOrCaptureSaysNullForBoth() throws {
        let pads = try XCTUnwrap(try object()["controllers"] as? [[String: Any]])
        let bare = try XCTUnwrap(pads.last)
        XCTAssertTrue(bare["record"] is NSNull)
        XCTAssertTrue(bare["capture"] is NSNull)
        XCTAssertEqual(bare["path"] as? String, "gameController")
        XCTAssertNil(bare["hardware"])
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
