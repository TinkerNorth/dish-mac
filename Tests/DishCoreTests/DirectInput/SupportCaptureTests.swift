// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// "Help support this controller": the device key a page is pushed with,
/// the guided sequence, and the plain-text report and issue link built
/// from what it recorded.
final class SupportCaptureTests: XCTestCase {

    private let device = SupportDevice(
        vendorId: 0x057E,
        productId: 0x2019,
        product: "N64 Controller",
        manufacturer: "Nintendo Co., Ltd.",
        transport: "USB",
        descriptor: Array(0 ..< 18)
    )

    private func stepping() -> SupportCaptureState {
        reduceSupportCapture(SupportCaptureState(), .deviceFound(device))
    }

    func testADeviceKeyNamesAUsbIdentityOrAProduct() {
        XCTAssertEqual(SupportTarget(deviceKey: "057e:2019"), .usb(vendorId: 0x057E, productId: 0x2019))
        XCTAssertEqual(SupportTarget.usb(vendorId: 0x057E, productId: 0x2019).deviceKey, "057e:2019")
        XCTAssertEqual(SupportTarget(deviceKey: "named:Pad: Pro"), .named("Pad: Pro"), "a name may hold a colon")
        XCTAssertEqual(SupportTarget.named("Pad").deviceKey, "named:Pad")
        for bad in ["", "057e", "57e:2019", "zzzz:2019", "057e:2019:1", "named:"] {
            XCTAssertNil(SupportTarget(deviceKey: bad), bad)
        }
    }

    func testReportsCountOnlyWhileAStepIsOnScreen() {
        let searching = reduceSupportCapture(SupportCaptureState(), .reports([[0x30]]))
        XCTAssertEqual(searching.phase, .searching)
        XCTAssertEqual(searching.current, [], "nothing is recorded before the device opens")
        let state = reduceSupportCapture(stepping(), .reports([[0x30], [0x31], [0x30]]))
        XCTAssertEqual(state.phase, .stepping)
        XCTAssertEqual(state.current, [[0x30], [0x31]], "distinct, in arrival order")
    }

    func testAStepKeepsAtMostItsCapOfReports() {
        let many = (0 ..< 40).map { [UInt8($0)] }
        XCTAssertEqual(reduceSupportCapture(stepping(), .reports(many)).current.count, SupportLimits.reportsPerStep)
    }

    func testNextRecordsTheStepAndSkipRecordsItSkipped() {
        let seen = reduceSupportCapture(stepping(), .reports([[0x30]]))
        let next = reduceSupportCapture(seen, .next)
        XCTAssertEqual(next.records, [SupportStepRecord(step: .atRest, reports: [[0x30]])])
        XCTAssertEqual(next.current, [])
        XCTAssertEqual(next.step, .pressA)
        let skipped = reduceSupportCapture(next, .skip)
        XCTAssertEqual(skipped.records.last, SupportStepRecord(step: .pressA, reports: nil))
    }

    func testTheSequenceEndsAfterItsLastStepAndALostDeviceIsLookedForAgain() {
        var state = stepping()
        for _ in SupportStep.allCases {
            state = reduceSupportCapture(state, .skip)
        }
        XCTAssertEqual(state.phase, .finished)
        XCTAssertEqual(reduceSupportCapture(state, .next), state, "a finished sequence records nothing more")
        XCTAssertEqual(SupportStep.allCases.count, 14)
        XCTAssertEqual(reduceSupportCapture(stepping(), .deviceLost).phase, .searching)
        XCTAssertEqual(reduceSupportCapture(SupportCaptureState(), .next).stepIndex, 0, "no device open, no step taken")
    }

    func testTheReportCarriesTheDeviceItsDescriptorAndEachStep() {
        var state = reduceSupportCapture(stepping(), .reports([[0x30, 0x6B], [0x30, 0x00]]))
        state = reduceSupportCapture(state, .next)
        state = reduceSupportCapture(state, .skip)
        state = reduceSupportCapture(state, .next)
        XCTAssertEqual(supportReportText(state), """
        Controller support capture (Dish for macOS)
        Product: N64 Controller
        Manufacturer: Nintendo Co., Ltd.
        VID:PID: 057e:2019
        Transport: USB

        HID report descriptor (18 bytes):
          00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f
          10 11

        Input reports per step:
        At rest:
          30 6b
          30 00
        Press A: skipped
        Press B: no reports
        """)
        XCTAssertEqual(supportReportText(SupportCaptureState()), "", "no device, no report")
    }

    func testTheIssueOpensWithItsTitleEncoded() throws {
        XCTAssertEqual(supportIssueTitle(device), "Controller support: N64 Controller (057e:2019)")
        let url = try XCTUnwrap(supportIssueURL(device))
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/TinkerNorth/dish-mac/issues/new?title=Controller%20support%3A%20N64%20Controller%20%28057e%3A2019%29"
        )
        let odd = SupportDevice(vendorId: 1, productId: 2, product: "A&B+C", manufacturer: "", transport: "", descriptor: [])
        XCTAssertTrue(try XCTUnwrap(supportIssueURL(odd)).absoluteString.contains("A%26B%2BC"), "& and + cannot end the title")
        let nameless = SupportDevice(vendorId: 1, productId: 2, product: "", manufacturer: "", transport: "", descriptor: [])
        XCTAssertEqual(supportIssueTitle(nameless), "Controller support: 0001:0002 (0001:0002)")
    }

    func testHexIsLowercasePairs() {
        XCTAssertEqual(hexBytes([0x00, 0xAB, 0x7F]), "00 ab 7f")
        XCTAssertEqual(hexBytes([]), "")
    }
}
