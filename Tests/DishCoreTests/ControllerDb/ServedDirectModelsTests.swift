// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A served row reaches the Direct path only after the table, only for a
/// family the HID reader compiles, and never past the probe that gates a
/// pad today; a record the build cannot carry is inert.
final class ServedDirectModelsTests: XCTestCase {

    private func record(
        _ family: String,
        usb: String = "1234:5678",
        rule: String = "auto",
        mapping: String? = nil,
        requires: [String]? = nil,
        ops: [String] = []
    ) -> [String: Any] {
        RecordFixture()
            .with(["id"], "served-\(family)")
            .with(["identity", "usb"], [usb])
            .with(["input", "protocol", "ref"], family)
            .with(["input", "direct", "rule"], rule)
            .with(["input", "mapping"], mapping)
            .with(["requires"], ["families": requires ?? [family], "ops": ops])
            .json
    }

    private func served(_ records: [[String: Any]]) throws -> ServedDirectModels {
        let strings = ["en": ["controller.served-hid.name": "Served Pad"]]
        let set = try XCTUnwrap(try PublishedSet(dbVersion: 2, records: records, strings: strings).set)
        return ServedDirectModels(index: ControllerIndex(set, source: .cache))
    }

    func testEachMacDecoderNamesItsFamily() {
        XCTAssertEqual(controllerFamily(of: .switchReport(.pro)), .switchProUsb)
        XCTAssertEqual(controllerFamily(of: .switchReport(.snes)), .switchProUsb)
        XCTAssertEqual(controllerFamily(of: .switchReport(.n64)), .switchN64Usb)
        XCTAssertEqual(controllerFamily(of: .hidGamepad(.western)), .hid)
        XCTAssertEqual(controllerFamily(of: .steamController), .steamController)
        XCTAssertEqual(controllerFamily(of: .steamControllerBle), .steamControllerBle)
        XCTAssertEqual(controllerFamily(of: .steamTriton), .steamTriton)
        XCTAssertEqual(controllerFamily(of: .xusb), .xinput360)
    }

    func testEachButtonOrderNamesItsMapping() {
        XCTAssertEqual(controllerMapping(of: .western), .western)
        XCTAssertEqual(controllerMapping(of: .nintendoSwitch), .nintendoSwitch)
        XCTAssertEqual(controllerMapping(of: .eightBitDo), .eightBitDo)
        XCTAssertEqual(controllerMapping(of: .playStationClassic), .playStationClassic)
    }

    func testAServedHidRowClassifiesANewIdInItsMapping() throws {
        let model = try XCTUnwrap(try served([record("hid", mapping: "eightbitdo")]).model(vendorId: 0x1234, productId: 0x5678))
        XCTAssertEqual(model.decoder, .hidGamepad(.eightBitDo))
        XCTAssertEqual(model.name, "Served Pad")
        XCTAssertEqual(model.family, .other)
        XCTAssertFalse(model.receiver)
    }

    func testAServedHidRowWithNoMappingIsReadWestern() throws {
        XCTAssertEqual(try served([record("hid")]).model(vendorId: 0x1234, productId: 0x5678)?.decoder, .hidGamepad(.western))
    }

    func testEachFamilyTheReaderCompilesGetsItsDecoder() throws {
        let cases: [(String, DirectDecoder)] = [
            ("switchProUsb", .switchReport(.pro)), ("switchN64Usb", .switchReport(.n64)), ("steamController", .steamController),
            ("steamControllerBle", .steamControllerBle), ("steamTriton", .steamTriton)
        ]
        for (family, decoder) in cases {
            XCTAssertEqual(try served([record(family)]).model(vendorId: 0x1234, productId: 0x5678)?.decoder, decoder, family)
        }
    }

    func testAServedNintendoRowIsANintendoPadGameControllerMayCarry() throws {
        let model = try XCTUnwrap(try served([record("switchProUsb", usb: "057e:2069")]).model(vendorId: 0x057E, productId: 0x2069))
        XCTAssertEqual(model.family, .nintendo)
        XCTAssertTrue(model.gameControllerCarriesOutput)
        XCTAssertTrue(model.offersStandard)
        let n64 = try XCTUnwrap(try served([record("switchN64Usb", usb: "057e:2068")]).model(vendorId: 0x057E, productId: 0x2068))
        XCTAssertFalse(n64.offersStandard, "macOS drops an N64 pad's input")
    }

    func testTheTableWinsOverAServedRowForTheSameId() throws {
        let models = try served([record("hid", usb: "057e:2009")])
        XCTAssertNil(models.model(vendorId: 0x057E, productId: 0x2009))
        XCTAssertEqual(directModel(vendorId: 0x057E, productId: 0x2009, served: models)?.decoder, .switchReport(.pro))
    }

    func testADeclinedIdentityIsNeverServed() throws {
        XCTAssertNil(try served([record("switchProUsb", usb: "057e:200e")]).model(vendorId: 0x057E, productId: 0x200E))
    }

    func testTheDataIsConsultedAfterTheTable() throws {
        let models = try served([record("hid")])
        XCTAssertEqual(directModel(vendorId: 0x1234, productId: 0x5678, served: models)?.decoder, .hidGamepad(.western))
        XCTAssertNil(directModel(vendorId: 0x1234, productId: 0x9999, served: models))
    }

    func testARecordThatRequiresAFamilyTheMacLacksIsInert() throws {
        let lacking = record("hid", requires: ["hid", "gameCubeAdapter"])
        XCTAssertTrue(try recordIsInert(decodeControllerDatabase(databaseData(records: [lacking])).get().records[0]))
        XCTAssertNil(try served([lacking]).model(vendorId: 0x1234, productId: 0x5678))
    }

    func testARecordThatRequiresAnOpIsInert() throws {
        XCTAssertNil(try served([record("hid", ops: ["writeTemplate"])]).model(vendorId: 0x1234, productId: 0x5678))
    }

    func testAFamilyNoMacDecoderParsesIsInert() throws {
        let dualsense = try decodeControllerDatabase(databaseData(records: [record("dualsense")])).get().records[0]
        XCTAssertTrue(recordIsInert(dualsense))
        let unknown = try decodeControllerDatabase(databaseData(records: [record("gameCubeAdapter")])).get().records[0]
        XCTAssertTrue(recordIsInert(unknown))
    }

    func testAnXusbRowIsNotInertButIsNotServedToTheHidReader() throws {
        let xusb = try decodeControllerDatabase(databaseData(records: [record("xinput360")])).get().records[0]
        XCTAssertFalse(recordIsInert(xusb))
        XCTAssertNil(try served([record("xinput360")]).model(vendorId: 0x1234, productId: 0x5678))
    }

    func testTheMacsProbeGatesEveryServedRule() {
        XCTAssertEqual(macDirectRule(.auto), .whenMacOSCannot, "auto waits for GameController's answer, as today")
        XCTAssertEqual(macDirectRule(.whenOsCannot), .whenMacOSCannot)
        XCTAssertEqual(macDirectRule(.optIn), .optIn)
    }

    func testOnlyAnOptInRowNeedsMatchingByIdentity() throws {
        let models = try served([record("hid"), record("steamTriton", usb: "28de:1399", rule: "optIn")])
        XCTAssertEqual(models.matchedByIdentity.map(\.productId), [0x1399])
    }

    func testAnIdentityKeyReadsAsItsTwoIds() {
        XCTAssertEqual(parseUsbPathKey("057e:2009").map { [$0.0, $0.1] }, [0x057E, 0x2009])
        XCTAssertNil(parseUsbPathKey("057e2009"))
        XCTAssertNil(parseUsbPathKey("57e:2009"))
        XCTAssertNil(parseUsbPathKey("zzzz:2009"))
    }
}
