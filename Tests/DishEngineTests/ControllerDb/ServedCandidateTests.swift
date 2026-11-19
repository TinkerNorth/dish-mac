// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit.hid
import XCTest
@testable import DishEngine

/// A served row reaching the HID reader: it classifies an id the table does
/// not name, never one the table names, and an inert record classifies
/// nothing. What the device showed of its report paths rides the candidate.
final class ServedCandidateTests: XCTestCase {

    private func served(family: String, usb: String, mapping: String? = nil, requires: [String]? = nil) throws -> ServedDirectModels {
        var input: [String: Any] = ["protocol": ["ref": family], "direct": ["rule": "auto"]]
        input["mapping"] = mapping
        let record: [String: Any] = [
            "schema": 1, "id": "served", "requires": ["families": requires ?? [family], "ops": []],
            "identity": ["usb": [usb], "bluetooth": []], "input": input,
            "support": ["verification": ["state": "imported"]]
        ]
        let database = try JSONSerialization.data(withJSONObject: ["schema": 1, "dbVersion": 2, "records": [record]])
        let set = try XCTUnwrap(parsedControllerDbSet(
            manifest: ControllerDbManifest(dbVersion: 2, files: [:]),
            files: [ControllerDbFiles.controllers: database]
        ))
        return ServedDirectModels(index: ControllerIndex(set, source: .cache))
    }

    func testAServedHidRowReadsANewPadInItsOwnButtonOrder() throws {
        let models = try served(family: "hid", usb: "1234:5678", mapping: "playstationClassic")
        let candidate = try XCTUnwrap(hidPadCandidate(DirectFixtures.gamepadProperties(), served: models))
        guard case let .hidGamepad(layout) = candidate.decoder else { return XCTFail("a descriptor lane") }
        XCTAssertEqual(layout.order, .playStationClassic)
        XCTAssertEqual(candidate.model?.rule, .whenMacOSCannot, "GameController's answer still gates it")
        XCTAssertEqual(candidate.name, "served", "a record with no name in the strings shows its id")
    }

    func testWithoutTheRowTheSamePadIsReadWestern() throws {
        let candidate = try XCTUnwrap(hidPadCandidate(DirectFixtures.gamepadProperties()))
        guard case let .hidGamepad(layout) = candidate.decoder else { return XCTFail("a descriptor lane") }
        XCTAssertEqual(layout.order, .western)
        XCTAssertNil(candidate.model)
    }

    func testAServedSwitchRowReadsANintendoIdTheTableDoesNotName() throws {
        let models = try served(family: "switchProUsb", usb: "057e:2069")
        XCTAssertNil(hidPadCandidate(DirectFixtures.nintendoProperties(productId: 0x2069)), "left to macOS without the row")
        let candidate = try XCTUnwrap(hidPadCandidate(DirectFixtures.nintendoProperties(productId: 0x2069), served: models))
        XCTAssertEqual(candidate.decoder, .switchReport(.pro))
    }

    func testTheTableWinsOverAServedRow() throws {
        let models = try served(family: "hid", usb: "057e:2019")
        let candidate = try XCTUnwrap(hidPadCandidate(DirectFixtures.nintendoProperties(productId: 0x2019), served: models))
        XCTAssertEqual(candidate.decoder, .switchReport(.n64))
    }

    func testAnInertRowClassifiesNothing() throws {
        let models = try served(family: "switchProUsb", usb: "057e:2069", requires: ["switchProUsb", "switch2Usb"])
        XCTAssertNil(hidPadCandidate(DirectFixtures.nintendoProperties(productId: 0x2069), served: models))
    }

    func testAServedOptInRowIsMatchedByItsIdentity() throws {
        let models = try served(family: "steamTriton", usb: "28de:1399")
        XCTAssertEqual(models.matchedByIdentity, [], "an auto row is met through the game usages")
        let matching = hidPadMatching(served: models)
        XCTAssertEqual(matching.count, hidPadMatching().count)
    }

    func testTheReportPathsADeviceDeclaresAreObserved() {
        var properties = DirectFixtures.gamepadProperties()
        XCTAssertEqual(observedReportPaths(properties), ObservedEndpoints(input: true, output: nil), "no size is not seen")
        properties[kIOHIDMaxOutputReportSizeKey] = 0
        XCTAssertEqual(observedReportPaths(properties), ObservedEndpoints(input: true, output: false))
        properties[kIOHIDMaxOutputReportSizeKey] = 48
        XCTAssertEqual(hidPadCandidate(properties)?.observedEndpoints, ObservedEndpoints(input: true, output: true))
    }
}
