// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import IOKit.hid
import XCTest
@testable import DishEngine

/// Which devices the Direct reader reads, from fake IOKit properties: the
/// Nintendo models by identity, any other gamepad by its descriptor, and
/// nothing synthetic, unnamed by the table from Nintendo, or not a pad.
final class HidPadCandidateTests: XCTestCase {

    func testTheN64PadIsReadByItsModelWithASwitchDecoder() throws {
        let candidate = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2019))
        XCTAssertEqual(candidate.decoder, .switchReport(.n64))
        XCTAssertEqual(candidate.name, "Nintendo N64 Online Controller", "the model's name, not IOKit's")
        XCTAssertEqual(candidate.family, .nintendo)
        XCTAssertEqual(candidate.transport, .usb)
        XCTAssertFalse(candidate.layoutGuessed, "a Switch table is never a guess")
        XCTAssertEqual(laneKindWord(candidate.decoder), "switch-n64")
    }

    func testTheProAndTheSnesPadTakeTheirOwnTables() throws {
        let pro = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2009))
        let snes = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2017))
        XCTAssertEqual(pro.decoder, .switchReport(.pro))
        XCTAssertEqual(snes.decoder, .switchReport(.snes))
    }

    func testASyntheticDeviceIsNeverRead() {
        var properties = DirectFixtures.nintendoProperties(productId: 0x2019)
        properties[kIOHIDGCSyntheticDeviceKey] = true
        XCTAssertNil(hidPadCandidate(properties))
    }

    func testJoyConsAndTheGripStayWithMacOSEvenWithAGamepadDescriptor() {
        for productId in [0x2006, 0x2007, 0x200E] {
            var properties = DirectFixtures.gamepadProperties(vendorId: 0x057E, productId: productId)
            properties[kIOHIDProductKey] = "Joy-Con"
            XCTAssertNil(hidPadCandidate(properties), String(format: "057e:%04x", productId))
        }
    }

    func testAnUnknownGamepadIsReadByItsDescriptorAndItsLayoutIsGuessed() throws {
        let candidate = try DirectFixtures.candidate(DirectFixtures.gamepadProperties())
        guard case let .hidGamepad(layout) = candidate.decoder else { return XCTFail("a descriptor-read pad") }
        XCTAssertEqual(layout.order, .western)
        XCTAssertEqual(layout.buttonCount, 10)
        XCTAssertTrue(candidate.layoutGuessed)
        XCTAssertEqual(candidate.name, "Generic Pad", "no model: IOKit's product string")
        XCTAssertEqual(candidate.family, .other)
        XCTAssertEqual(laneKindWord(candidate.decoder), "hid-western")
    }

    func testAVerifiedModelReadsInItsOwnOrderAndIsNoGuess() throws {
        let candidate = try DirectFixtures.candidate(DirectFixtures.gamepadProperties(vendorId: 0x2DC8, productId: 0x5006))
        guard case let .hidGamepad(layout) = candidate.decoder else { return XCTFail("a descriptor-read pad") }
        XCTAssertEqual(layout.order, .eightBitDo)
        XCTAssertFalse(candidate.layoutGuessed)
        XCTAssertEqual(candidate.name, "8BitDo M30 (D-input)")
    }

    func testAPadOfAnUnlistedModelFromAVerifiedVendorIsStillAGuess() throws {
        let candidate = try DirectFixtures.candidate(DirectFixtures.gamepadProperties(vendorId: 0x2DC8, productId: 0x9999))
        XCTAssertTrue(candidate.layoutGuessed)
    }

    func testADeviceWithoutAGameUsageOrADescriptorIsLeftAlone() {
        var keyboard = DirectFixtures.gamepadProperties()
        keyboard[kIOHIDPrimaryUsageKey] = 0x06
        XCTAssertNil(hidPadCandidate(keyboard), "a keyboard usage")
        var silent = DirectFixtures.gamepadProperties()
        silent.removeValue(forKey: kIOHIDReportDescriptorKey)
        XCTAssertNil(hidPadCandidate(silent), "no descriptor to read")
        let nothingPadLike = DirectFixtures.gamepadProperties(descriptor: [0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0xC0])
        XCTAssertNil(hidPadCandidate(nothingPadLike), "a descriptor with no axis, hat or button")
    }

    func testAGameUsageListedOnlyInTheUsagePairsCounts() {
        var properties = DirectFixtures.gamepadProperties()
        properties.removeValue(forKey: kIOHIDPrimaryUsageKey)
        properties[kIOHIDDeviceUsagePairsKey] = [[kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x04]]
        XCTAssertNotNil(hidPadCandidate(properties))
    }

    func testTheReportBufferIsTheLargestReportButNeverUnderSixtyFourBytes() throws {
        var large = DirectFixtures.nintendoProperties(productId: 0x2009)
        large[kIOHIDMaxInputReportSizeKey] = 362
        XCTAssertEqual(try DirectFixtures.candidate(large).reportCapacity, 362)
        XCTAssertEqual(try DirectFixtures.candidate(DirectFixtures.gamepadProperties()).reportCapacity, 64)
    }

    func testAPadWithNoProductStringIsNamedByItsUsbIdentity() throws {
        var properties = DirectFixtures.gamepadProperties()
        properties.removeValue(forKey: kIOHIDProductKey)
        XCTAssertEqual(try DirectFixtures.candidate(properties).name, "1234:5678")
    }

    func testTheMatchingNamesEachNintendoModelAndEveryGameUsageNeverSynthetic() {
        let matching = hidPadMatching()
        let products = matching.compactMap { $0[kIOHIDProductIDKey] as? Int }
        XCTAssertEqual(Set(products), [0x2009, 0x2019, 0x2017])
        let usages = matching.compactMap { $0[kIOHIDDeviceUsageKey] as? Int }
        XCTAssertEqual(Set(usages), [0x04, 0x05, 0x08])
        XCTAssertTrue(matching.allSatisfy { $0[kIOHIDGCSyntheticDeviceKey] as? Bool == false })
    }

    // MARK: - Slot ids

    func testIdenticalPadsTakeTheLowestFreeOrdinal() {
        let base = directSlotBase(vendorId: 0x057E, productId: 0x2019)
        XCTAssertEqual(base, "hid:057e:2019")
        XCTAssertEqual(lowestFreeSlotId(base: base, taken: []), base)
        XCTAssertEqual(lowestFreeSlotId(base: base, taken: [base]), "\(base)#1")
        XCTAssertEqual(lowestFreeSlotId(base: base, taken: [base, "\(base)#2"]), "\(base)#1")
        XCTAssertEqual(lowestFreeSlotId(base: base, taken: [base, "\(base)#1"]), "\(base)#2")
    }

    // MARK: - GameController's answer

    func testAYesSettlesAtOnceAndANoOnlyAfterTheLastCheck() {
        XCTAssertEqual(settledSupport(supported: true, attempt: 1), .shows)
        XCTAssertEqual(settledSupport(supported: false, attempt: 1), .pending)
        XCTAssertEqual(settledSupport(supported: false, attempt: GameControllerSettle.checks - 1), .pending)
        XCTAssertEqual(settledSupport(supported: false, attempt: GameControllerSettle.checks), .doesNotShow)
        let windowMs = GameControllerSettle.intervalMs * (GameControllerSettle.checks - 1)
        XCTAssertEqual(windowMs, 30, "about 30 ms, as SDL waits")
    }

    func testTheTransportWordsInADevcapsLine() {
        XCTAssertEqual(transportWord(.usb), "usb")
        XCTAssertEqual(transportWord(.bluetooth), "bluetooth")
        XCTAssertEqual(transportWord(.other("SPI")), "SPI")
        XCTAssertEqual(transportWord(.unknown), "unknown")
    }
}
