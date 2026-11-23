// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The one reader of `controllers.json`: a schema 1 file becomes immutable
/// records, a record that does not decode is left out alone, unknown fields
/// are ignored and any other schema is refused whole.
final class ControllerDbDecoderTests: XCTestCase {

    private func decode(_ records: [[String: Any]]) throws -> [ControllerRecord] {
        try decodeControllerDatabase(databaseData(records: records)).get().records
    }

    func testAWellFormedRecordDecodesEverySection() throws {
        let record = try XCTUnwrap(decode([RecordFixture().json]).first)
        XCTAssertEqual(record.id, "sony-dualsense")
        XCTAssertEqual(record.requiredFamilies, ["dualsense"])
        XCTAssertEqual(record.usb, ["054c:0ce6"])
        XCTAssertEqual(record.family, .dualsense)
        XCTAssertEqual(record.directRule, .auto)
        XCTAssertEqual(record.inputCapabilities, ControllerInputCapabilities(motion: true, touchpad: true, battery: true))
        XCTAssertEqual(record.outputRoute, .interruptOut)
        XCTAssertEqual(record.initKind, "none")
        XCTAssertTrue(record.outputCapabilities.triggerEffects)
        XCTAssertEqual(record.expect, ControllerExpect(endpointIn: true, endpointOut: true))
        XCTAssertEqual(record.verification, .verified)
        XCTAssertEqual(record.issues.first?.id, "thor-ds5-rumble-usb")
        XCTAssertEqual(record.issues.first?.device, "AYN Thor")
        XCTAssertEqual(record.issues.first?.os, ["android": 15])
        XCTAssertEqual(record.issues.first?.transport, .usb)
    }

    func testAnIssuesOsIsANumberOrAVersionStringReadByItsMajorVersion() throws {
        let os: [String: Any] = ["android": "15", "macos": "26.1", "linux": 6.8, "windows": 11, "ios": "next", "futureos": ["x": 1]]
        let issue: [String: Any] = ["id": "i", "os": os, "status": "open"]
        let record = try XCTUnwrap(decode([RecordFixture().with(["support", "issues"], [issue]).json]).first, "text keeps the record")
        XCTAssertEqual(
            record.issues.first?.os,
            ["android": 15, "macos": 26, "linux": 6, "windows": 11],
            "what names no version is left out"
        )
    }

    func testTheMacOverrideReplacesTheRecordsOwnRule() throws {
        let record = try XCTUnwrap(decode([RecordFixture().with(["platforms"], ["mac": ["direct": ["rule": "whenOsCannot"]]]).json]).first)
        XCTAssertEqual(record.directRule, .whenOsCannot)
    }

    func testAnotherPlatformsOverrideIsNotTheMacs() throws {
        let record = try XCTUnwrap(decode([RecordFixture().with(["platforms"], ["android": ["direct": ["rule": "optIn"]]]).json]).first)
        XCTAssertEqual(record.directRule, .auto)
    }

    func testUnknownAndReservedFieldsAreIgnored() throws {
        let fixture = RecordFixture()
            .with(["lifecycle"], ["onAttach": "x"])
            .with(["input", "protocol", "fields"], [1, 2])
            .with(["expect", "rateHz"], 250)
        XCTAssertEqual(try decode([fixture.json]).count, 1)
    }

    func testARecordThatDoesNotDecodeIsLeftOutAndTheRestStand() throws {
        let broken = [
            RecordFixture().with(["id"], nil),
            RecordFixture().with(["input", "direct", "rule"], "sometimes"),
            RecordFixture().with(["support", "verification", "state"], "rumoured"),
            RecordFixture().with(["input", "mapping"], "eastern"),
            RecordFixture().with(["output", "route"], "pigeon"),
            RecordFixture().with(["schema"], 2),
            RecordFixture().with(["id"], "")
        ]
        let records = try decode(broken.map(\.json) + [RecordFixture().with(["id"], "good").json])
        XCTAssertEqual(records.map(\.id), ["good"])
    }

    func testAFamilyThisBuildDoesNotKnowStillReads() throws {
        let record = try XCTUnwrap(decode([RecordFixture().with(["input", "protocol", "ref"], "gameCubeAdapter").json]).first)
        XCTAssertEqual(record.familyId, "gameCubeAdapter")
        XCTAssertNil(record.family)
    }

    func testAbsentOptionalSectionsReadAsNothing() throws {
        let bare = RecordFixture().with(["output"], nil).with(["expect"], nil).with(["requires"], nil).with(["identity"], nil)
        let record = try XCTUnwrap(decode([bare.json]).first)
        XCTAssertNil(record.outputRoute)
        XCTAssertEqual(record.expect, ControllerExpect())
        XCTAssertEqual(record.requiredFamilies, [])
        XCTAssertEqual(record.usb, [])
    }

    func testANullRouteIsAPadWithNoOutput() throws {
        let record = try XCTUnwrap(decode([RecordFixture().with(["output", "route"], NSNull()).json]).first)
        XCTAssertNil(record.outputRoute)
    }

    func testAnUnknownExpectationReadsUnknown() throws {
        let record = try XCTUnwrap(decode([RecordFixture().with(["expect", "endpoints", "out"], NSNull()).json]).first)
        XCTAssertEqual(record.expect, ControllerExpect(endpointIn: true, endpointOut: nil))
    }

    func testIdentitiesAreReadLowercase() throws {
        let record = try XCTUnwrap(decode([RecordFixture().with(["identity", "usb"], ["054C:0CE6"]).json]).first)
        XCTAssertEqual(record.usb, ["054c:0ce6"])
    }

    func testAnIssueOnATransportThisSchemaDoesNotNameIsOnEveryTransport() throws {
        let issue = ["id": "x", "transport": "carrierPigeon"]
        let record = try XCTUnwrap(decode([RecordFixture().with(["support", "issues"], [issue]).json]).first)
        XCTAssertNil(record.issues.first?.transport)
    }

    func testAMappingIsReadByItsDataName() throws {
        let hid = RecordFixture().with(["input", "protocol", "ref"], "hid").with(["input", "mapping"], "switch")
        XCTAssertEqual(try decode([hid.json]).first?.mapping, .nintendoSwitch)
    }

    func testAnySchemaButOneIsRefusedWhole() throws {
        XCTAssertEqual(try decodeControllerDatabase(databaseData(schema: 2, records: [RecordFixture().json])), .failure(.unsupportedSchema))
        XCTAssertEqual(
            try decodeControllerDatabase(databaseData(schema: nil, records: [RecordFixture().json])),
            .failure(.unsupportedSchema)
        )
    }

    func testABodyThatIsNotTheFilesShapeIsBadJson() {
        XCTAssertEqual(decodeControllerDatabase(Data("<html>".utf8)), .failure(.badJson))
        XCTAssertEqual(decodeControllerDatabase(Data("[]".utf8)), .failure(.badJson))
        XCTAssertEqual(decodeControllerDatabase(Data(#"{"schema":1}"#.utf8)), .failure(.badJson))
    }

    func testTheFilesVersionIsKept() throws {
        XCTAssertEqual(try decodeControllerDatabase(databaseData(dbVersion: 7, records: [])).get().dbVersion, 7)
    }
}
