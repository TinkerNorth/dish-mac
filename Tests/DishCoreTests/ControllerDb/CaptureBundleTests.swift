// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The Help-support capture in the file: `usb-descriptors-v1` on the pad it
/// was taken of, IOKit's report descriptor marked as the operating system's
/// copy, and the guided steps' text beside it in `extra`.
final class CaptureBundleTests: XCTestCase {

    private static let app = BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github")
    private static let device = BundleDeviceFacts(model: "Mac14,2", os: "macOS 26.1", arch: "arm64")

    private static let capture = BundleCapture(
        device: "Transport: USB\nVendorID: 054c",
        product: "Wireless Controller",
        manufacturer: "Sony",
        interfaceNumber: 3,
        reportDescriptor: [0x05, 0x01, 0x09, 0x05],
        restReports: [RestReport(atMs: 1_763_585_990_000, bytes: [0x01, 0x80]), RestReport(atMs: 1_763_585_990_004, bytes: [0x01, 0x80])]
    )

    private func fixture() -> DiagnosticsBundleFacts {
        DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: Self.app,
            device: Self.device,
            controllerDb: ControllerDbStatus(),
            pads: [BundlePadFacts(record: nil, transport: .usb, path: .direct, hardware: nil, capture: Self.capture)],
            hosts: [],
            log: [],
            supportCaptureText: "VID:PID 054c:0ce6"
        )
    }

    private func object(_ facts: DiagnosticsBundleFacts) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
    }

    func testTheCaptureIsUsbDescriptorsV1() throws {
        let pad = try XCTUnwrap(try (object(fixture())["controllers"] as? [[String: Any]])?.first)
        let capture = try XCTUnwrap(pad["capture"] as? [String: Any])
        XCTAssertEqual(capture["format"] as? String, "usb-descriptors-v1")
        XCTAssertEqual(capture["device"] as? String, "Transport: USB\nVendorID: 054c", "text from IOKit's properties")
        XCTAssertTrue(capture["configuration"] is NSNull, "a capture whose device gave no configuration descriptors")
        XCTAssertEqual(capture["strings"] as? [String: String], ["manufacturer": "Sony", "product": "Wireless Controller"])
        XCTAssertEqual(
            capture["hidReportDescriptors"] as? [[String: AnyHashable]],
            [["interface": 3, "hex": "05010905", "source": "os"]]
        )
        XCTAssertEqual(capture["restReports"] as? [[String: AnyHashable]], [
            ["atMs": 1_763_585_990_000, "hex": "0180"],
            ["atMs": 1_763_585_990_004, "hex": "0180"]
        ])
        XCTAssertEqual(Set(capture.keys), ["format", "device", "configuration", "strings", "hidReportDescriptors", "restReports"])
    }

    func testTheConfigurationIsEveryConfigurationDescriptorAsHexWhereIOKitHandsThemOver() throws {
        let described = Self.capture.with(configuration: [[0x09, 0x02, 0x29, 0x00], [0x09, 0x02, 0x22, 0x00]])
        let facts = DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: Self.app,
            device: Self.device,
            controllerDb: ControllerDbStatus(),
            pads: [BundlePadFacts(record: nil, transport: .usb, path: .gameController, hardware: nil, capture: described)],
            hosts: [],
            log: []
        )
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
        let capture = try XCTUnwrap(((file["controllers"] as? [[String: Any]])?.first)?["capture"] as? [String: Any])
        XCTAssertEqual(capture["configuration"] as? String, "0902290009022200", "in index order, as dish-android writes it")
    }

    func testTheGuidedStepsRideAsTheMacsTextCaptureInExtra() throws {
        let extra = try XCTUnwrap(try object(fixture())["extra"] as? [String: Any])
        XCTAssertEqual(extra["supportCapture"] as? [String: String], ["format": "support-capture-text", "text": "VID:PID 054c:0ce6"])
    }

    func testAFileWithNoCaptureHasNoExtra() throws {
        let facts = DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: Self.app,
            device: Self.device,
            controllerDb: ControllerDbStatus(),
            pads: [],
            hosts: [],
            log: []
        )
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
        XCTAssertNil(file["extra"])
    }

    func testADescriptorWhoseInterfaceIOKitDoesNotNameSaysNullAndANameNotGivenIsNull() throws {
        let overBluetooth = BundleCapture(
            device: "Transport: Bluetooth",
            product: "Pad",
            manufacturer: nil,
            interfaceNumber: nil,
            reportDescriptor: [0x05, 0x01],
            restReports: []
        )
        let facts = DiagnosticsBundleFacts(
            createdAtMs: 0,
            app: Self.app,
            device: Self.device,
            controllerDb: ControllerDbStatus(),
            pads: [BundlePadFacts(record: nil, transport: .bluetooth, path: .direct, hardware: nil, capture: overBluetooth)],
            hosts: [],
            log: []
        )
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticsBundleJSON(facts)) as? [String: Any])
        let capture = try XCTUnwrap(((file["controllers"] as? [[String: Any]])?.first)?["capture"] as? [String: Any])
        let descriptor = try XCTUnwrap((capture["hidReportDescriptors"] as? [[String: Any]])?.first)
        XCTAssertTrue(descriptor["interface"] is NSNull)
        XCTAssertTrue((capture["strings"] as? [String: Any])?["manufacturer"] is NSNull)
        XCTAssertEqual(capture["restReports"] as? [[String: AnyHashable]], [])
    }
}
