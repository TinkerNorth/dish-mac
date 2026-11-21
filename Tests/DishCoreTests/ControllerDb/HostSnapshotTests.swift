// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Each host's own view in the bundle: the connection's document from a
/// Satellite that has the route, the stand-in and the reason otherwise, and
/// a Moonlight host's serverinfo without its name.
final class HostSnapshotTests: XCTestCase {

    private static let document = Data(#"{"format":"satellite-connection-diagnostics.v1","satellite":{"version":"2.3.0","uptimeS":3600}}"#
        .utf8)

    private func reply(_ status: Int, _ body: Data = Data(), timedOut: Bool = false) -> HostSnapshotReply {
        HostSnapshotReply(status: status, body: body, timedOut: timedOut)
    }

    private static let serverInfoXml = """
    <?xml version="1.0" encoding="utf-8"?>
    <root status_code="200"><hostname>Living Room PC</hostname><appversion>7.1.431.-1</appversion>\
    <uniqueid>ABCDEF</uniqueid><mac>00:11:22:33:44:55</mac><LocalIP>192.168.1.20</LocalIP>\
    <PairStatus>1</PairStatus><currentgame>881448767</currentgame><state>SUNSHINE_SERVER_BUSY</state></root>
    """

    private static let capabilities = SatelliteCapabilitiesFacts(
        serverVersion: "2.2.0",
        protocolVersion: 4,
        backends: .array([.object(["id": .string("vigem"), "available": .bool(true)])]),
        controllerAudio: HostAudioBlock(enabled: true, mic: false, speaker: true, hapticAudio: false),
        catalogVersion: 2
    )

    func testTheContractsDocumentIsTheSnapshot() {
        let verdict = hostSnapshotVerdict(reply(200, Self.document))
        guard case let .snapshot(document) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(document["satellite"]?["uptimeS"], .integer(3600))
    }

    func testANotFoundFromASatelliteWithTheRouteIsAnUnknownConnection() {
        XCTAssertEqual(hostSnapshotVerdict(reply(404)), .failed(.unknownConnection))
    }

    func testASatelliteOf230OrLaterIsAsked() {
        XCTAssertTrue(satelliteAnswersDiagnostics(serverVersion: "2.3.0"))
        XCTAssertTrue(satelliteAnswersDiagnostics(serverVersion: "2.10.1"))
        XCTAssertTrue(satelliteAnswersDiagnostics(serverVersion: "3.0.0"))
    }

    func testASatelliteOlderThan230IsNotAsked() {
        XCTAssertFalse(satelliteAnswersDiagnostics(serverVersion: "2.2.9"))
        XCTAssertFalse(satelliteAnswersDiagnostics(serverVersion: "1.6.0"))
    }

    func testASatelliteWhoseVersionCannotBeRankedIsNotAsked() {
        XCTAssertFalse(satelliteAnswersDiagnostics(serverVersion: ""))
        XCTAssertFalse(satelliteAnswersDiagnostics(serverVersion: "dev"))
    }

    func testARefusedProofIsUnauthorized() {
        XCTAssertEqual(hostSnapshotVerdict(reply(401)), .failed(.unauthorized))
        XCTAssertEqual(hostSnapshotVerdict(reply(403)), .failed(.unauthorized))
    }

    func testNoAnswerWithinTheWindowIsATimeoutWhateverElseArrived() {
        XCTAssertEqual(hostSnapshotVerdict(reply(0, timedOut: true)), .failed(.timeout))
        XCTAssertEqual(hostSnapshotVerdict(reply(200, Self.document, timedOut: true)), .failed(.timeout))
    }

    func testNoResponseAtAllIsOffline() {
        XCTAssertEqual(hostSnapshotVerdict(reply(0)), .failed(.offline))
    }

    func testAServerErrorIsABadReply() {
        XCTAssertEqual(hostSnapshotVerdict(reply(500)), .failed(.badReply))
        XCTAssertEqual(hostSnapshotVerdict(reply(503)), .failed(.badReply))
    }

    func testABodyThatIsNotTheDocumentIsABadReply() {
        XCTAssertEqual(hostSnapshotVerdict(reply(200, Data("not json".utf8))), .failed(.badReply))
        XCTAssertEqual(hostSnapshotVerdict(reply(200, Data(#"{"format":"something-else"}"#.utf8))), .failed(.badReply))
    }

    func testTheStandInIsMarkedAndCarriesWhatTheProbeSaid() {
        let standIn = capabilitiesSnapshot(Self.capabilities)
        XCTAssertEqual(standIn["format"], .string("satellite-capabilities"))
        XCTAssertEqual(standIn["serverVersion"], .string("2.2.0"))
        XCTAssertEqual(standIn["protocol"], .array([.integer(1), .integer(4)]))
        XCTAssertEqual(standIn["backends"], Self.capabilities.backends)
        XCTAssertEqual(standIn["controllerAudio"]?["speaker"], .bool(true))
        XCTAssertEqual(standIn["catalogVersion"], .integer(2))
    }

    func testAStandInWithoutTheOptionalBlocksLeavesThemOut() {
        let bare = SatelliteCapabilitiesFacts(
            serverVersion: "2.0.0",
            protocolVersion: 1,
            backends: nil,
            controllerAudio: nil,
            catalogVersion: nil
        )
        let standIn = capabilitiesSnapshot(bare)
        XCTAssertEqual(standIn["backends"], .array([]))
        XCTAssertNil(standIn["controllerAudio"])
        XCTAssertNil(standIn["catalogVersion"])
    }

    func testASatelliteThatAnsweredHasNoError() throws {
        let document = try XCTUnwrap(parseJSONValue(Self.document))
        let entry = satelliteHostSnapshot(.snapshot(document), fallback: Self.capabilities)
        XCTAssertEqual(entry, BundleHostSnapshot(snapshot: document, error: nil))
    }

    func testAnOlderSatelliteGetsTheStandInAndItsReason() {
        let entry = satelliteHostSnapshot(.failed(.olderSatellite), fallback: Self.capabilities)
        XCTAssertEqual(entry.error, .olderSatellite)
        XCTAssertEqual(entry.snapshot?["format"], .string("satellite-capabilities"))
    }

    func testAFailureWithNothingCachedHasOnlyItsReason() {
        XCTAssertEqual(satelliteHostSnapshot(.failed(.timeout), fallback: nil), BundleHostSnapshot(snapshot: nil, error: .timeout))
    }

    func testASatelliteNoLiveLinkReachedWasNotAskedAndReadsOffline() {
        let entry = satelliteHostSnapshot(nil, fallback: Self.capabilities)
        XCTAssertEqual(entry.error, .offline)
        XCTAssertEqual(entry.snapshot?["serverVersion"], .string("2.2.0"))
    }

    func testAMoonlightHostIsItsServerinfoWithoutItsName() throws {
        let info = try XCTUnwrap(MoonlightXml.serverInfo(Self.serverInfoXml))
        let entry = moonlightHostSnapshot(info)
        let snapshot = try XCTUnwrap(entry.snapshot)
        XCTAssertNil(entry.error)
        XCTAssertEqual(
            snapshot,
            .object([
                "format": .string("moonlight-serverinfo"),
                "appVersion": .string("7.1.431.-1"),
                "state": .null,
                "pairStatus": .null
            ]),
            "the plaintext serverinfo reports every host free and every caller unpaired"
        )
    }

    func testAMoonlightHostNeverProbedIsOffline() {
        XCTAssertEqual(moonlightHostSnapshot(nil), BundleHostSnapshot(snapshot: nil, error: .offline))
    }
}
