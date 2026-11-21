// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The second cut of `dish-diagnostics.v1`: the report, the device's
/// conditions, each host from both ends and every controller path, added
/// beside the first cut's keys.
final class DiagnosticsReportBundleTests: XCTestCase {

    private enum Forbidden {
        static let hostName = "Emir's Gaming PC"
        static let address = "192.168.1.44"
    }

    private static let session = BundleSessionFacts(
        slots: [
            BundleSessionSlot(
                index: 0,
                record: "sony-dualsense",
                requestedType: "dualsense",
                appliedType: "dualsense",
                backend: "hidmaestro",
                result: "ok",
                touchpadMode: "ds4"
            ),
            BundleSessionSlot(index: 1, record: nil, requestedType: "0", appliedType: nil, backend: nil, result: nil, touchpadMode: "off")
        ],
        ack: HeartbeatAck(backendAvailable: true, activeCount: 1, epoch: 12, bitmap: 0x0001),
        latency: LatencySummary(p50RttMs: 2.1, p99RttMs: 4.8, samples: 120, capacity: 128),
        counts: WireCounts(sent: [.input: 12345, .battery: 3], received: [.rumble: 12, .lightbar: 2])
    )

    private static let document = JSONValue.object([
        "format": .string("satellite-connection-diagnostics.v1"),
        "log": .array([.object(["message": .string("\(Forbidden.hostName) accepted this connection")])]),
        "peers": .object([Forbidden.address: .string("seen")])
    ])

    private static let pad = BundlePadFacts(
        record: ControllerRecord(id: "sony-dualsense", familyId: "dualsense", verification: .verified),
        transport: .bluetooth,
        bluetoothLayer: .classic,
        path: .gameController,
        hardware: nil,
        lastWrite: DirectWriteVerdict(route: .interruptOut, reportId: 2, status: 0, atMs: 5),
        input: BundlePadInput(frames: 12345, rateHz: 250, last: GamepadReport(buttons: 0x1000, lx: -12, extButtons: 0)),
        output: BundlePadOutput(
            counts: PadOutputCounts(
                rumble: 12,
                lastRumble: RumbleFacts(strong: 32768, weak: 0, durationMs: 100, atMs: 1_763_586_000_000),
                lightbar: 2,
                lastLightbar: LightbarFacts(r: 0, g: 0, b: 255, atMs: 1_763_586_000_001),
                playerLeds: 1,
                lastPlayer: 1,
                triggerEffects: 0
            ),
            rumbleTarget: .framework,
            lastWrite: nil,
            micLed: "on",
            speaker: BundleVoice(voice: .open, device: "pad", frames: 40),
            haptics: BundleVoice(voice: .closed, device: "pad", frames: 0)
        )
    )

    private func facts(report: SupportReport?, conditions: BundleDeviceConditions?, asked: Bool) -> DiagnosticsBundleFacts {
        let host = BundleHostFacts(
            names: [Forbidden.hostName, Forbidden.address],
            kind: .satellite,
            version: "2.3.0",
            protocolVersion: 4,
            link: "connected",
            grants: HostAudioVerdict(mic: false, speaker: true, hapticAudio: false),
            session: Self.session,
            snapshot: asked ? BundleHostSnapshot(snapshot: Self.document, error: nil) : nil
        )
        return DiagnosticsBundleFacts(
            createdAtMs: 1_763_586_251_000,
            app: BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github"),
            device: BundleDeviceFacts(model: "Mac14,2", os: "macOS 26.1", arch: "arm64"),
            controllerDb: ControllerDbStatus(),
            pads: [Self.pad],
            hosts: [host],
            log: [],
            report: report,
            conditions: conditions
        )
    }

    private func object(_ facts: DiagnosticsBundleFacts) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
    }

    private func reported() throws -> [String: Any] {
        let report = SupportReport(category: .noFeedback, text: "Returnal never rumbles over USB.", controller: "sony-dualsense")
        let conditions = BundleDeviceConditions(
            battery: BundleBattery(level: 81, charging: false),
            thermal: .fair,
            powerSave: false,
            wifi: BundleWifi(band: "5", rssiDbm: -54, linkSpeedMbps: 867),
            usbHost: true
        )
        return try object(facts(report: report, conditions: conditions, asked: true))
    }

    private func host() throws -> [String: Any] {
        let hosts = try XCTUnwrap(try reported()["hosts"] as? [[String: Any]])
        return try XCTUnwrap(hosts.first)
    }

    private func controller() throws -> [String: Any] {
        let controllers = try XCTUnwrap(try reported()["controllers"] as? [[String: Any]])
        return try XCTUnwrap(controllers.first)
    }

    func testTheReportCarriesTheCategoryTheWordsAndTheController() throws {
        let report = try XCTUnwrap(try reported()["report"] as? [String: Any])
        XCTAssertEqual(report["category"] as? String, "noFeedback")
        XCTAssertEqual(report["text"] as? String, "Returnal never rumbles over USB.")
        XCTAssertEqual(report["controller"] as? String, "sony-dualsense")
    }

    func testAReportAboutNoControllerSaysNull() throws {
        let report = SupportReport(category: .question, text: "Does Dish work with Apollo?", controller: nil)
        let file = try object(facts(report: report, conditions: nil, asked: false))
        let block = try XCTUnwrap(file["report"] as? [String: Any])
        XCTAssertTrue(block["controller"] is NSNull)
    }

    func testAFileSavedWithoutAReportHasNoReportBlock() throws {
        XCTAssertNil(try object(facts(report: nil, conditions: nil, asked: false))["report"])
    }

    func testTheDeviceGainsItsConditionsWhenTheyWereRead() throws {
        let device = try XCTUnwrap(try reported()["device"] as? [String: Any])
        XCTAssertEqual(device["battery"] as? [String: AnyHashable], ["level": 81, "charging": false])
        XCTAssertEqual(device["thermal"] as? String, "fair")
        XCTAssertEqual(device["powerSave"] as? Bool, false)
        XCTAssertEqual(device["wifi"] as? [String: AnyHashable], ["band": "5", "rssiDbm": -54, "linkSpeedMbps": 867])
        XCTAssertEqual(device["usbHost"] as? Bool, true, "measured: macOS lists a USB host controller")
    }

    func testAMacWithoutABatteryOrALinkSaysNull() throws {
        let conditions = BundleDeviceConditions(battery: nil, thermal: .nominal, powerSave: false, wifi: nil)
        let file = try object(facts(report: nil, conditions: conditions, asked: false))
        let device = try XCTUnwrap(file["device"] as? [String: Any])
        XCTAssertTrue(device["battery"] is NSNull)
        XCTAssertTrue(device["wifi"] is NSNull)
        XCTAssertTrue(device["usbHost"] is NSNull, "no answer from IOKit is not an answer")
    }

    func testAMacThatListsNoUsbHostControllerSaysFalse() throws {
        let conditions = BundleDeviceConditions(battery: nil, thermal: .nominal, powerSave: false, wifi: nil, usbHost: false)
        let device = try XCTUnwrap(try object(facts(report: nil, conditions: conditions, asked: false))["device"] as? [String: Any])
        XCTAssertEqual(device["usbHost"] as? Bool, false)
    }

    func testConditionsNotReadAreNotWritten() throws {
        let device = try XCTUnwrap(try object(facts(report: nil, conditions: nil, asked: false))["device"] as? [String: Any])
        XCTAssertEqual(Set(device.keys), ["model", "os", "arch"])
    }

    func testTheSessionCarriesItsSlotsAckRoundTripAndCounts() throws {
        let session = try XCTUnwrap(try host()["session"] as? [String: Any])
        let slots = try XCTUnwrap(session["slots"] as? [[String: Any]])
        XCTAssertEqual(slots.first?["backend"] as? String, "hidmaestro")
        XCTAssertEqual(slots.first?["touchpadMode"] as? String, "ds4")
        XCTAssertTrue(slots.last?["appliedType"] is NSNull)
        let ack = try XCTUnwrap(session["ack"] as? [String: AnyHashable])
        XCTAssertEqual(ack, ["backendAvailable": true, "activeControllers": 1, "epoch": 12, "activeBitmap": "0001"])
        let rtt = try XCTUnwrap(session["rtt"] as? [String: AnyHashable])
        XCTAssertEqual(rtt, ["p50Ms": 2.1, "p99Ms": 4.8, "samples": 120])
    }

    func testEveryKindIsCountedAZeroIncluded() throws {
        let session = try XCTUnwrap(try host()["session"] as? [String: Any])
        let sent = try XCTUnwrap(session["sent"] as? [String: Int])
        let received = try XCTUnwrap(session["received"] as? [String: Int])
        XCTAssertEqual(sent, ["input": 12345, "heartbeat": 0, "motion": 0, "battery": 3, "pointer": 0, "mic": 0])
        XCTAssertEqual(Set(received.keys), Set(WireReceivedKind.allCases.map(\.name)))
        XCTAssertEqual(received["rumble"], 12)
        XCTAssertEqual(received["sessionClose"], 0)
    }

    func testTheHostsOwnDocumentRidesWholeAndAliased() throws {
        let entry = try host()
        let snapshot = try XCTUnwrap(entry["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["format"] as? String, "satellite-connection-diagnostics.v1")
        let log = try XCTUnwrap(snapshot["log"] as? [[String: String]])
        XCTAssertEqual(log.first?["message"], "Host 1 accepted this connection")
        XCTAssertEqual(snapshot["peers"] as? [String: String], ["Host 1": "seen"], "keys are aliased too")
        XCTAssertTrue(entry["snapshotError"] is NSNull)
    }

    func testAHostWhoseKindsAreNotCountedSaysNull() throws {
        let uncounted = BundleSessionFacts(
            slots: [BundleSessionSlot(
                index: 0,
                record: nil,
                requestedType: "1",
                appliedType: nil,
                backend: nil,
                result: nil,
                touchpadMode: nil
            )],
            ack: nil,
            latency: LatencySummary(p50RttMs: 9, p99RttMs: nil, samples: 1, capacity: 1),
            counts: nil
        )
        let host = BundleHostFacts(
            names: [],
            kind: .moonlight,
            version: nil,
            protocolVersion: nil,
            link: "connected",
            grants: nil,
            session: uncounted
        )
        let file = try object(DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github"),
            device: BundleDeviceFacts(model: "Mac14,2", os: "macOS 26.1", arch: "arm64"),
            controllerDb: ControllerDbStatus(),
            pads: [],
            hosts: [host],
            log: []
        ))
        let session = try XCTUnwrap(((file["hosts"] as? [[String: Any]])?.first)?["session"] as? [String: Any])
        XCTAssertTrue(session["sent"] is NSNull)
        XCTAssertTrue(session["received"] is NSNull)
        XCTAssertTrue(session["ack"] is NSNull)
        XCTAssertTrue((session["slots"] as? [[String: Any]])?.first?["touchpadMode"] is NSNull)
    }

    func testAHostNotAskedHasNeitherSnapshotKey() throws {
        let file = try object(facts(report: nil, conditions: nil, asked: false))
        let entry = try XCTUnwrap((file["hosts"] as? [[String: Any]])?.first)
        XCTAssertNil(entry["snapshot"])
        XCTAssertNil(entry["snapshotError"])
    }

    func testTheControllerCarriesWhatWentIn() throws {
        let input = try XCTUnwrap(try controller()["input"] as? [String: Any])
        XCTAssertEqual(input["frames"] as? Int, 12345)
        XCTAssertEqual(input["rateHz"] as? Int, 250)
        let last = try XCTUnwrap(input["last"] as? [String: AnyHashable])
        XCTAssertEqual(last["buttons"], "1000")
        XCTAssertEqual(last["lx"], -12)
        XCTAssertEqual(last["ext"], "00000000")
    }

    func testTheControllerCarriesWhatCameOutLaneByLane() throws {
        let output = try XCTUnwrap(try controller()["output"] as? [String: Any])
        let rumble = try XCTUnwrap(output["rumble"] as? [String: Any])
        XCTAssertEqual(rumble["count"] as? Int, 12)
        XCTAssertEqual(rumble["target"] as? String, "framework")
        XCTAssertEqual((rumble["last"] as? [String: Int])?["strong"], 32768)
        XCTAssertEqual((rumble["lastWrite"] as? [String: Any])?["route"] as? String, "interruptOut")
        XCTAssertEqual((output["lightbar"] as? [String: Any])?["count"] as? Int, 2)
        XCTAssertEqual(((output["playerLeds"] as? [String: Any])?["last"] as? [String: Int])?["player"], 1)
        XCTAssertEqual((output["triggerEffects"] as? [String: Any])?["count"] as? Int, 0)
    }

    func testALaneThisMacCannotCountSaysNull() throws {
        let output = try XCTUnwrap(try controller()["output"] as? [String: Any])
        XCTAssertTrue((output["triggerRumble"] as? [String: Any])?["count"] is NSNull)
        let micLed = try XCTUnwrap(output["micLed"] as? [String: Any])
        XCTAssertTrue(micLed["count"] is NSNull)
        XCTAssertEqual((micLed["last"] as? [String: String])?["state"], "on")
    }

    func testTheVoicesCarryThePlan() throws {
        let output = try XCTUnwrap(try controller()["output"] as? [String: Any])
        XCTAssertEqual(output["speaker"] as? [String: AnyHashable], ["voice": "open", "device": "pad", "frames": 40])
        XCTAssertEqual((output["haptics"] as? [String: Any])?["voice"] as? String, "closed")
    }

    func testABluetoothPadNamesItsProfileItsLinkAndNoAddress() throws {
        let bluetooth = try XCTUnwrap(try controller()["bluetooth"] as? [String: Any])
        XCTAssertEqual(bluetooth["profile"] as? String, "hid")
        XCTAssertEqual(bluetooth["transportLayer"] as? String, "classic")
        XCTAssertEqual(Set(bluetooth.keys), ["profile", "transportLayer"])
    }

    func testNoForbiddenWordReachesTheFile() throws {
        let report = SupportReport(category: .connection, text: "Lag", controller: nil)
        let text = try XCTUnwrap(String(
            bytes: diagnosticsBundleJSON(facts(report: report, conditions: .unknown, asked: true)),
            encoding: .utf8
        ))
        XCTAssertFalse(text.contains(Forbidden.hostName))
        XCTAssertFalse(text.contains(Forbidden.address))
    }
}
