// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The source a pad starts on: Nintendo's pads by model, the rest by
/// whether GameController supports them, and the user's stored pick.
final class InputSourceDecisionTests: XCTestCase {

    private let pro = directModel(vendorId: 0x057E, productId: 0x2009)
    private let n64 = directModel(vendorId: 0x057E, productId: 0x2019)
    private let m30 = directModel(vendorId: 0x2DC8, productId: 0x5006)
    private let steam = directModel(vendorId: 0x28DE, productId: 0x1102)

    private func facts(
        _ model: DirectModel?,
        decodable: Bool = true,
        _ gameController: GameControllerSupport,
        stored: InputSource? = nil
    ) -> PadPathFacts {
        PadPathFacts(model: model, decodable: decodable, gameController: gameController, stored: stored)
    }

    func testTheStorageTokensAreTheFleets() {
        XCTAssertEqual(InputSource.standard.rawValue, "standard")
        XCTAssertEqual(InputSource.direct.rawValue, "direct")
        XCTAssertEqual(InputSource.fromStorage("direct"), .direct)
        XCTAssertNil(InputSource.fromStorage("auto"), "a token a newer build wrote is no choice")
        XCTAssertNil(InputSource.fromStorage(nil))
    }

    // MARK: - Direct by model

    func testANintendoPadGoesDirectByModelWhateverGameControllerSays() {
        for support in [GameControllerSupport.pending, .shows, .doesNotShow] {
            XCTAssertEqual(decidePath(facts(n64, support)), .forward(.direct, .directByModel))
            XCTAssertEqual(decidePath(facts(pro, support)), .forward(.direct, .directByModel))
        }
    }

    func testAStoredStandardSendsASwitchProThatGameControllerShowsBack() {
        XCTAssertEqual(decidePath(facts(pro, .shows, stored: .standard)), .forward(.standard, .userPicked))
    }

    func testAStoredStandardForASwitchProWaitsForGameControllerToSettle() {
        XCTAssertEqual(decidePath(facts(pro, .pending, stored: .standard)), .awaitGameController)
    }

    func testAStoredStandardForASwitchProGameControllerDoesNotShowStaysDirect() {
        XCTAssertEqual(decidePath(facts(pro, .doesNotShow, stored: .standard)), .forward(.direct, .directByModel))
    }

    func testAStoredStandardIsIgnoredForTheN64() {
        XCTAssertEqual(decidePath(facts(n64, .shows, stored: .standard)), .forward(.direct, .directByModel))
    }

    // MARK: - By GameController's support

    func testAPadGameControllerReadsStaysStandard() {
        XCTAssertEqual(decidePath(facts(nil, .shows)), .forward(.standard, .macOSReads))
        XCTAssertEqual(decidePath(facts(nil, decodable: false, .shows)), .forward(.standard, .macOSReads))
    }

    func testAStoredStandardOnAPadGameControllerReadsIsTheUsersPick() {
        XCTAssertEqual(decidePath(facts(nil, .shows, stored: .standard)), .forward(.standard, .userPicked))
    }

    func testAPadGameControllerCannotReadGoesDirectWhenDishDecodesIt() {
        XCTAssertEqual(decidePath(facts(nil, .doesNotShow)), .forward(.direct, .macOSCannotRead))
        XCTAssertEqual(decidePath(facts(m30, .doesNotShow)), .forward(.direct, .macOSCannotRead))
    }

    func testAKnownHidModelGameControllerReadsStaysStandard() {
        XCTAssertEqual(decidePath(facts(m30, .shows)), .forward(.standard, .macOSReads))
    }

    func testAPadNeitherPathReadsIsUnreadable() {
        XCTAssertEqual(decidePath(facts(nil, decodable: false, .doesNotShow)), .unreadable)
    }

    func testAnUnsettledSupportWaits() {
        XCTAssertEqual(decidePath(facts(nil, .pending)), .awaitGameController)
        XCTAssertEqual(decidePath(facts(nil, .pending, stored: .standard)), .awaitGameController)
    }

    func testAStoredDirectWinsForADecodablePadWithoutWaiting() {
        XCTAssertEqual(decidePath(facts(nil, .pending, stored: .direct)), .forward(.direct, .userPicked))
        XCTAssertEqual(decidePath(facts(m30, .shows, stored: .direct)), .forward(.direct, .userPicked))
    }

    func testAStoredDirectForAPadDishCannotDecodeIsIgnored() {
        XCTAssertEqual(decidePath(facts(nil, decodable: false, .shows, stored: .direct)), .forward(.standard, .macOSReads))
    }

    // MARK: - Which paths a pick may choose

    func testDirectIsAvailableExactlyWhenDishDecodesThePad() {
        XCTAssertTrue(pathAvailable(.direct, facts(nil, .shows)))
        XCTAssertFalse(pathAvailable(.direct, facts(nil, decodable: false, .shows)))
    }

    func testStandardIsAvailableWhenGameControllerShowsAModelThatAllowsIt() {
        XCTAssertTrue(pathAvailable(.standard, facts(nil, .shows)))
        XCTAssertTrue(pathAvailable(.standard, facts(pro, .shows)))
        XCTAssertFalse(pathAvailable(.standard, facts(pro, .pending)))
        XCTAssertFalse(pathAvailable(.standard, facts(pro, .doesNotShow)))
        XCTAssertFalse(pathAvailable(.standard, facts(n64, .shows)), "never the N64")
    }

    // MARK: - Opt-in models

    func testAnOptInPadIsOfferedOnlyOnceGameControllerHasSaidNo() {
        XCTAssertEqual(decidePath(facts(steam, .pending)), .awaitGameController)
        XCTAssertEqual(decidePath(facts(steam, .doesNotShow)), .offerDirect, "reading it turns its keyboard and mouse off")
    }

    func testAnOptInPadIsDirectOnlyWhenTheUserPickedIt() {
        for support in [GameControllerSupport.pending, .shows, .doesNotShow] {
            XCTAssertEqual(decidePath(facts(steam, support, stored: .direct)), .forward(.direct, .userPicked))
        }
    }

    func testAnOptInPadHandedBackStaysOffered() {
        XCTAssertEqual(decidePath(facts(steam, .doesNotShow, stored: .standard)), .offerDirect)
    }

    func testAnOptInPadGameControllerReadsIsStandard() {
        XCTAssertEqual(decidePath(facts(steam, .shows)), .forward(.standard, .macOSReads))
        XCTAssertEqual(decidePath(facts(steam, .shows, stored: .standard)), .forward(.standard, .userPicked))
    }

    func testAnOptInPadCanAlwaysBeHandedBackToMacOS() {
        XCTAssertTrue(pathAvailable(.standard, facts(steam, .doesNotShow)), "macOS keeps it as a keyboard and mouse")
        XCTAssertTrue(pathAvailable(.standard, facts(steam, .shows)))
        XCTAssertTrue(pathAvailable(.direct, facts(steam, .doesNotShow)))
    }
}
