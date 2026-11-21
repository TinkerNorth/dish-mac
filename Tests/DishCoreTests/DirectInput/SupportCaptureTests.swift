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

    // MARK: - At rest

    private let rest = [RestReport(atMs: 10, bytes: [0x30, 0x00]), RestReport(atMs: 14, bytes: [0x30, 0x00])]

    func testTheReportsAtRestAreTakenWhileTheFirstStepShows() {
        XCTAssertEqual(SupportStep.allCases.first, .atRest)
        XCTAssertEqual(reduceSupportCapture(stepping(), .restTaken(rest)).rest, rest, "repeats are kept: their times carry the rate")
    }

    func testTheReportsAtRestAreTwentyAtMost() {
        let many = (0 ..< 25).map { RestReport(atMs: Int64($0), bytes: [0x30]) }
        let taken = reduceSupportCapture(stepping(), .restTaken(many))
        XCTAssertEqual(SupportLimits.restReports, 20)
        XCTAssertEqual(taken.rest, Array(many.prefix(20)), "the first twenty, in arrival order")
    }

    func testReportsAtRestCountOnlyAtTheFirstStepWithTheDeviceOpen() {
        XCTAssertEqual(reduceSupportCapture(SupportCaptureState(), .restTaken(rest)).rest, [], "nothing before the device opens")
        let pressing = reduceSupportCapture(stepping(), .next)
        XCTAssertEqual(reduceSupportCapture(pressing, .restTaken(rest)).rest, [], "a press is not at rest")
    }

    func testEachReportAtRestIsPlacedOnTheWallClockByItsAge() {
        let timed = [
            TimedReport(bytes: [1], uptimeNs: 9_000_000_000),
            TimedReport(bytes: [2], uptimeNs: 9_004_000_000),
            TimedReport(bytes: [3], uptimeNs: 10_500_000_000)
        ]
        let placed = restReports(timed, nowUptimeNs: 10_000_000_000, nowWallMs: 1_763_586_000_000)
        let expected = [
            RestReport(atMs: 1_763_585_999_000, bytes: [1]),
            RestReport(atMs: 1_763_585_999_004, bytes: [2]),
            RestReport(atMs: 1_763_586_000_000, bytes: [3])
        ]
        XCTAssertEqual(placed, expected, "a report stamped after the clock was read is placed at it")
    }

    // MARK: - usb-descriptors-v1

    private var described: SupportDevice {
        SupportDevice(
            vendorId: 0x057E,
            productId: 0x2019,
            product: "N64 Controller",
            manufacturer: "",
            transport: "USB",
            descriptor: [0x05, 0x01],
            interfaceNumber: 0,
            facts: [SupportDeviceFact(key: "Transport", value: "USB"), SupportDeviceFact(key: "VendorID", value: "057e")]
        )
    }

    func testTheCaptureCarriesTheDevicesFactsItsStringsItsDescriptorAndTheRest() throws {
        let found = reduceSupportCapture(SupportCaptureState(), .deviceFound(described))
        let state = reduceSupportCapture(found, .restTaken(rest))
        let capture = try XCTUnwrap(bundleCapture(state))
        XCTAssertEqual(capture.device, "Transport: USB\nVendorID: 057e")
        XCTAssertEqual(capture.product, "N64 Controller")
        XCTAssertNil(capture.manufacturer, "a name the device does not give is no string")
        XCTAssertEqual(capture.interfaceNumber, 0)
        XCTAssertEqual(capture.reportDescriptor, [0x05, 0x01])
        XCTAssertEqual(capture.restReports, rest)
    }

    func testNoDeviceIsNoCapture() {
        XCTAssertNil(bundleCapture(SupportCaptureState()))
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
