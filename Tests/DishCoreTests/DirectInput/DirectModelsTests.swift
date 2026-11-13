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
        let valve = directModels.filter { $0.vendorId == DirectVendor.valve }.count
        XCTAssertEqual(valve, 5, "the 2015 pad and its dongle, the 2026 pad and its two receivers")
        let xusb = directModels.filter { $0.decoder == .xusb }.count
        XCTAssertEqual(xusb, 1, "the Ultimate 2 in X-input mode")
        XCTAssertEqual(
            directModels.count,
            cases.count + 3 + valve + xusb,
            "no row beyond the three Nintendo pads, the desktops' list, Valve's and the XUSB pads"
        )
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

    // MARK: - Valve's controllers

    func testTheSteamControllersAreOptInAndReadByTheirOwnDecoders() throws {
        let cases: [(UInt16, DirectDecoder, Bool)] = [
            (0x1102, .steamController, false), (0x1142, .steamController, true),
            (0x1302, .steamTriton, false), (0x1304, .steamTriton, true), (0x1305, .steamTriton, true)
        ]
        for (productId, decoder, receiver) in cases {
            let found = try model(0x28DE, productId)
            XCTAssertEqual(found.decoder, decoder)
            XCTAssertEqual(found.receiver, receiver, "a receiver carries a controller per interface, connected or not")
            XCTAssertEqual(found.rule, .optIn, "reading it turns its keyboard and mouse off, so only on the user's word")
            XCTAssertEqual(found.family, .other)
            XCTAssertTrue(found.hasMotion)
            XCTAssertFalse(found.gameControllerCarriesOutput)
        }
    }

    func testOnlyTheTwentyTwentySixPadDrivesItsOwnRumble() throws {
        XCTAssertFalse(try model(0x28DE, 0x1102).drivesItsOwnRumble, "the 2015 pad has trackpad voice coils, no motors")
        XCTAssertFalse(try model(0x28DE, 0x1142).drivesItsOwnRumble)
        XCTAssertTrue(try model(0x28DE, 0x1302).drivesItsOwnRumble)
        XCTAssertTrue(try model(0x28DE, 0x1304).drivesItsOwnRumble)
        XCTAssertFalse(try model(0x057E, 0x2009).drivesItsOwnRumble, "a Nintendo pad's rumble rides GameController")
    }

    func testTheSteamControllersAndTheSwitchProSourceTheExtendedButtons() throws {
        let sources: [(vendor: UInt16, product: UInt16)] = [
            (0x28DE, 0x1102), (0x28DE, 0x1142), (0x28DE, 0x1302), (0x28DE, 0x1304), (0x28DE, 0x1305), (0x057E, 0x2009)
        ]
        for pad in sources {
            XCTAssertTrue(try model(pad.vendor, pad.product).hasExtendedButtons, String(pad.product, radix: 16))
        }
        let none: [(vendor: UInt16, product: UInt16)] = [(0x057E, 0x2019), (0x057E, 0x2017), (0x2DC8, 0x5006), (0x054C, 0x0CDA)]
        for pad in none {
            XCTAssertFalse(try model(pad.vendor, pad.product).hasExtendedButtons, String(pad.product, radix: 16))
        }
    }

    func testTheBluetoothSteamControllerIsLeftToMacOS() {
        XCTAssertNil(directModel(vendorId: 0x28DE, productId: 0x1303), "Dish reads no Bluetooth LE pad")
    }

    // MARK: - Which interface carries the controller

    func testThe2015PadIsReadOnItsVendorInterface() throws {
        for productId: UInt16 in [0x1102, 0x1142] {
            let steam = try model(0x28DE, productId)
            XCTAssertTrue(steamInterfaceCarriesController(steam, usagePage: 0xFF00, usage: 0x0001, interfaceNumber: 2))
            XCTAssertFalse(steamInterfaceCarriesController(steam, usagePage: 0x01, usage: 0x06, interfaceNumber: 1), "its keyboard")
            XCTAssertFalse(steamInterfaceCarriesController(steam, usagePage: 0x01, usage: 0x02, interfaceNumber: 0), "its mouse")
            XCTAssertFalse(steamInterfaceCarriesController(steam, usagePage: nil, usage: nil, interfaceNumber: nil))
        }
    }

    func testTheWired2026PadIsOneUnifiedInterface() throws {
        let wired = try model(0x28DE, 0x1302)
        XCTAssertTrue(steamInterfaceCarriesController(wired, usagePage: 0x01, usage: 0x06, interfaceNumber: 0))
        XCTAssertTrue(steamInterfaceCarriesController(wired, usagePage: nil, usage: nil, interfaceNumber: nil))
    }

    func testA2026ReceiverCarriesItsControllersOnInterfacesTwoToFiveAndNeverItsPogoPins() throws {
        for productId: UInt16 in [0x1304, 0x1305] {
            let puck = try model(0x28DE, productId)
            for slot in 2 ... 5 {
                XCTAssertTrue(steamInterfaceCarriesController(puck, usagePage: 0xFF00, usage: 0x0001, interfaceNumber: slot))
            }
            XCTAssertFalse(steamInterfaceCarriesController(puck, usagePage: 0xFF00, usage: 0x0002, interfaceNumber: 6), "the pogo pins")
            XCTAssertFalse(steamInterfaceCarriesController(puck, usagePage: 0xFF00, usage: 0x0002, interfaceNumber: nil))
            XCTAssertFalse(steamInterfaceCarriesController(puck, usagePage: 0xFF00, usage: 0x0001, interfaceNumber: 1))
            XCTAssertTrue(steamInterfaceCarriesController(puck, usagePage: 0xFF00, usage: 0x0001, interfaceNumber: nil))
        }
    }

    func testAPadThatIsNotValvesHasNoSteamInterface() throws {
        XCTAssertFalse(try steamInterfaceCarriesController(model(0x057E, 0x2009), usagePage: 0xFF00, usage: 0x0001, interfaceNumber: 2))
        XCTAssertFalse(try steamInterfaceCarriesController(model(0x2DC8, 0x310B), usagePage: 0xFF00, usage: 0x0001, interfaceNumber: 0))
    }

    // MARK: - The XUSB pads

    func testTheUltimate2InXInputModeIsReadThroughItsXusbInterfaceBecauseMacOSCannot() throws {
        let ultimate = try model(0x2DC8, 0x310B)
        XCTAssertEqual(ultimate.name, "8BitDo Ultimate 2 Wireless Controller", "dish-android's and xpad's name")
        XCTAssertEqual(ultimate.decoder, .xusb)
        XCTAssertEqual(ultimate.rule, .whenMacOSCannot, "macOS has no driver for it, so GameController never lists it")
        XCTAssertEqual(ultimate.family, .other)
        XCTAssertFalse(ultimate.offersStandard, "GameController never reads it")
        XCTAssertFalse(ultimate.gameControllerCarriesOutput)
        XCTAssertFalse(ultimate.receiver, "xpad reads it as a wired 360 pad")
        XCTAssertTrue(ultimate.layoutVerified, "dish-android's verified fast lane")
    }

    func testAnXusbPadDrivesItsOwnRumbleAndHasNoMotionExtrasOrTrackpads() throws {
        let ultimate = try model(0x2DC8, 0x310B)
        XCTAssertTrue(ultimate.drivesItsOwnRumble, "its rumble report goes out on the interface's OUT pipe")
        XCTAssertFalse(ultimate.hasMotion)
        XCTAssertFalse(ultimate.hasExtendedButtons, "XUSB carries no paddles and no Capture")
        XCTAssertEqual(ultimate.trackpads, .none)
        XCTAssertNil(steamPlan(ultimate))
        XCTAssertEqual(hidButtonOrder(vendorId: 0x2DC8, productId: 0x310B), .western, "an XUSB report is not a HID order")
    }
}
