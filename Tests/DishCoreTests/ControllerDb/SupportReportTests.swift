// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The person's report and the Mac's conditions, each in the contract's
/// words, and never more than the person typed or the Mac should say.
final class SupportReportTests: XCTestCase {

    func testTheCategoriesAreTheContractsSix() {
        XCTAssertEqual(
            SupportReportCategory.allCases.map(\.rawValue),
            ["notRecognised", "noFeedback", "connection", "audio", "other", "question"]
        )
    }

    func testAPadWithARecordIsNamedByIt() {
        let record = ControllerRecord(id: "sony-dualsense", familyId: "dualsense", verification: .verified)
        XCTAssertEqual(reportedController(record: record, product: "Wireless Controller"), "sony-dualsense")
    }

    func testAPadWithoutARecordIsNamedByWhatItCallsItself() {
        XCTAssertEqual(reportedController(record: nil, product: "Wireless Controller"), "Wireless Controller")
    }

    func testOnlyTheCategoryOfTheSubjectIsInThePersonsLanguage() {
        XCTAssertEqual(
            supportMailSubject(category: "Pas de vibration ni de retour", version: "1.4.0", model: "Mac14,2"),
            "Dish support: Pas de vibration ni de retour · Dish for macOS 1.4.0 on Mac14,2"
        )
    }

    func testTheWordsAreTrimmedAndOtherwiseKept() {
        XCTAssertEqual(reportText("  It never rumbles.\nOver USB.  \n"), "It never rumbles.\nOver USB.")
    }

    func testEachThermalStateIsTheContractsWord() {
        XCTAssertEqual((0 ... 3).map { bundleThermal(rawValue: $0) }, [.nominal, .fair, .serious, .critical])
    }

    func testAThermalStateANewerMacOSAddsIsUnknown() {
        XCTAssertNil(bundleThermal(rawValue: 4))
    }

    func testAnAssociatedLinkCarriesItsBandSignalAndRate() {
        XCTAssertEqual(
            bundleWifi(bandGHz: "5", rssiDbm: -54, transmitRateMbps: 866.6),
            BundleWifi(band: "5", rssiDbm: -54, linkSpeedMbps: 867)
        )
    }

    func testARateOfZeroIsNotKnown() {
        XCTAssertEqual(bundleWifi(bandGHz: nil, rssiDbm: -70, transmitRateMbps: 0)?.linkSpeedMbps, nil)
    }

    func testAZeroSignalIsNoLink() {
        XCTAssertNil(bundleWifi(bandGHz: "2.4", rssiDbm: 0, transmitRateMbps: 144))
    }
}
