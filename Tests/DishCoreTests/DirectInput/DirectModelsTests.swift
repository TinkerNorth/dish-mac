// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The pads Dish reads itself: Nintendo's by model, the desktops' known HID
/// models when macOS cannot, verified by vendor as the desktops verify them.
final class DirectModelsTests: XCTestCase {

    private func model(_ vendorId: UInt16, _ productId: UInt16) throws -> DirectModel {
        try XCTUnwrap(directModel(vendorId: vendorId, productId: productId), usbPathKey(vendorId: vendorId, productId: productId))
    }

    func testTheNintendoPadsAreDirectByModelWithTheirSwitchDecoder() throws {
        let cases: [(UInt16, SwitchPadKind)] = [(0x2009, .pro), (0x2019, .n64), (0x2017, .snes)]
        for (productId, kind) in cases {
            let found = try model(0x057E, productId)
            XCTAssertEqual(found.decoder, .switchReport(kind))
            XCTAssertEqual(found.rule, .byModel)
            XCTAssertEqual(found.family, .nintendo)
            XCTAssertTrue(found.layoutVerified)
            XCTAssertTrue(found.gameControllerCarriesOutput, "rumble and lights stay with macOS when the pairing is unambiguous")
        }
    }

    func testOnlyTheSwitchProOffersStandardAndNeverTheN64() throws {
        XCTAssertTrue(try model(0x057E, 0x2009).offersStandard)
        XCTAssertFalse(try model(0x057E, 0x2019).offersStandard, "macOS lists the N64 and delivers none of its input")
        XCTAssertFalse(try model(0x057E, 0x2017).offersStandard)
    }

    func testOnlyTheSwitchProCarriesMotion() throws {
        XCTAssertTrue(try model(0x057E, 0x2009).hasMotion)
        XCTAssertFalse(try model(0x057E, 0x2019).hasMotion)
        XCTAssertFalse(try model(0x057E, 0x2017).hasMotion)
        XCTAssertFalse(try model(0x2DC8, 0x5006).hasMotion)
    }

    func testJoyConsAndTheChargingGripStayWithMacOS() {
        for productId: UInt16 in [0x2006, 0x2007, 0x200E] {
            XCTAssertNil(directModel(vendorId: 0x057E, productId: productId))
        }
    }

    func testTheKnownHidModelsAreTheDesktopsInTheirOwnOrders() throws {
        let cases: [(UInt16, UInt16, HidButtonOrder)] = [
            (0x054C, 0x0CDA, .playStationClassic),
            (0x2DC8, 0x3100, .eightBitDo), (0x2DC8, 0x3105, .eightBitDo), (0x2DC8, 0x5006, .eightBitDo),
            (0x0E6F, 0x0180, .nintendoSwitch), (0x0E6F, 0x0181, .nintendoSwitch), (0x0E6F, 0x0184, .nintendoSwitch),
            (0x0E6F, 0x0185, .nintendoSwitch), (0x0E6F, 0x0187, .nintendoSwitch)
        ]
        for (vendorId, productId, order) in cases {
            let found = try model(vendorId, productId)
            XCTAssertEqual(found.decoder, .hidGamepad(order))
            XCTAssertEqual(found.rule, .whenMacOSCannot)
            XCTAssertEqual(found.family, .other)
            XCTAssertFalse(found.gameControllerCarriesOutput, "macOS does not see these pads")
            XCTAssertEqual(hidButtonOrder(vendorId: vendorId, productId: productId), order)
        }
        XCTAssertEqual(directModels.count, cases.count + 3, "no row beyond the three Nintendo pads and the desktops' list")
    }

    func testTheAfterglowWirelessIsLeftOutBecauseItSpeaksTheSwitchProProtocol() {
        XCTAssertNil(directModel(vendorId: 0x0E6F, productId: 0x0186))
        XCTAssertEqual(hidButtonOrder(vendorId: 0x0E6F, productId: 0x0186), .western)
    }

    func testAnUnknownPadIsReadInTheWesternOrder() {
        XCTAssertEqual(hidButtonOrder(vendorId: 0x2DC8, productId: 0x9015), .western)
        XCTAssertEqual(hidButtonOrder(vendorId: 0x057E, productId: 0x2009), .western, "a Switch report is not a HID order")
    }

    func testALayoutIsVerifiedBySonyNintendoOrEightBitDoAndGuessedOtherwise() throws {
        XCTAssertTrue(hidLayoutVerified(vendorId: 0x054C))
        XCTAssertTrue(hidLayoutVerified(vendorId: 0x057E))
        XCTAssertTrue(hidLayoutVerified(vendorId: 0x2DC8))
        XCTAssertFalse(hidLayoutVerified(vendorId: 0x0E6F))
        XCTAssertFalse(hidLayoutVerified(vendorId: 0x046D))
        XCTAssertTrue(try model(0x054C, 0x0CDA).layoutVerified)
        XCTAssertTrue(try model(0x2DC8, 0x5006).layoutVerified)
        XCTAssertFalse(try model(0x0E6F, 0x0180).layoutVerified, "the PDP pads' layout is guessed")
    }

    func testGameControllersCategoryNamesTheDirectByModelPad() {
        XCTAssertEqual(directModel(gameControllerCategory: "Switch Pro Controller")?.productId, 0x2009)
        XCTAssertEqual(directModel(gameControllerCategory: "Switch N64 Controller")?.productId, 0x2019)
        XCTAssertEqual(directModel(gameControllerCategory: "N64 Controller")?.productId, 0x2019, "the Bluetooth name")
        XCTAssertEqual(directModel(gameControllerCategory: "Switch SNES Controller")?.productId, 0x2017)
        XCTAssertNil(directModel(gameControllerCategory: "Nintendo Switch Joy-Con (L/R)"))
        XCTAssertNil(directModel(gameControllerCategory: "Switch NES Controller"), "NES is not SNES")
        XCTAssertNil(directModel(gameControllerCategory: "DualSense Wireless Controller"))
    }

    func testTheUsbPathKeyIsTheFleetsLowercaseHexPair() {
        XCTAssertEqual(usbPathKey(vendorId: 0x057E, productId: 0x2019), "057e:2019")
        XCTAssertEqual(usbPathKey(vendorId: 0x2DC8, productId: 0x0005), "2dc8:0005")
    }
}
