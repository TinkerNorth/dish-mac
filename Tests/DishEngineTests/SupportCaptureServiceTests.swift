// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import IOKit.hid
import XCTest
@testable import DishEngine

/// Records what the service asked of the capture, and hands it the reports
/// a test queues.
final class FakeHidReportCapture: HidReportCapturing, @unchecked Sendable {
    private let box = LockedBox<(targets: [SupportTarget], stops: Int, queued: [[UInt8]], events: HidCaptureEvents?)>(([], 0, [], nil))
    private let restBox = LockedBox<[TimedReport]>([])

    /// What the capture holds at rest, as its thread stamped it.
    func holdAtRest(_ reports: [TimedReport]) {
        restBox.set(reports)
    }

    func restReports() -> [TimedReport] {
        restBox.get()
    }

    var targets: [SupportTarget] {
        box.get().targets
    }

    var stops: Int {
        box.get().stops
    }

    var events: HidCaptureEvents? {
        box.get().events
    }

    func queue(_ reports: [[UInt8]]) {
        box.mutate { $0.queued += reports }
    }

    func start(target: SupportTarget, events: HidCaptureEvents) {
        box.mutate { state in
            state.targets.append(target)
            state.events = events
        }
    }

    func stop() {
        box.mutate { $0.stops += 1 }
    }

    func drain() -> [[UInt8]] {
        box.mutate { state in
            let reports = state.queued
            state.queued = []
            return reports
        }
    }
}

/// "Help support this controller" on the main actor: the capture opens the
/// device the key names, its reports reach the sequence on the service's
/// own timer, the last step stops it and keeps the result, and leaving the
/// page ends it. The ring and the device pick are tested beside it.
@MainActor
final class SupportCaptureServiceTests: XCTestCase {

    private let device = SupportDevice(
        vendorId: 0x1234,
        productId: 0x5678,
        product: "Pad",
        manufacturer: "",
        transport: "USB",
        descriptor: []
    )
    private var capture: FakeHidReportCapture!
    private var scheduler: ManualPathScheduler!
    private var service: SupportCaptureService!

    /// Uptime 10 s and 1_763_586_000_000 on the wall clock, read together.
    private static let clocks = CaptureClocks(uptimeNs: { 10_000_000_000 }, wallMs: { 1_763_586_000_000 })

    override func setUp() {
        super.setUp()
        capture = FakeHidReportCapture()
        scheduler = ManualPathScheduler()
        service = SupportCaptureService(capture: capture, scheduler: scheduler, clocks: Self.clocks)
    }

    func testAKeyThatNamesNoDeviceOpensNothing() {
        service.begin(deviceKey: "nonsense")
        XCTAssertEqual(service.state?.known, false)
        XCTAssertEqual(capture.targets, [])
        XCTAssertEqual(scheduler.liveTimers.count, 0)
    }

    func testTheFoundDeviceStartsTheStepsAndItsReportsArriveOnTheTimer() throws {
        service.begin(deviceKey: "1234:5678")
        XCTAssertEqual(capture.targets, [.usb(vendorId: 0x1234, productId: 0x5678)])
        XCTAssertEqual(service.state?.capture.phase, .searching)
        try XCTUnwrap(capture.events).found(device)
        drainMain()
        XCTAssertEqual(service.state?.capture.phase, .stepping)
        capture.queue([[0x01], [0x02]])
        try XCTUnwrap(scheduler.liveTimers.first).fire()
        XCTAssertEqual(service.state?.capture.current, [[0x01], [0x02]])
        try XCTUnwrap(capture.events).lost()
        drainMain()
        XCTAssertEqual(service.state?.capture.phase, .searching)
    }

    func testTheLastStepStopsTheCaptureAndKeepsTheResult() throws {
        service.begin(deviceKey: "1234:5678")
        try XCTUnwrap(capture.events).found(device)
        drainMain()
        for _ in SupportStep.allCases {
            service.send(.skip)
        }
        XCTAssertEqual(service.state?.capture.phase, .finished)
        XCTAssertEqual(capture.stops, 2, "one stop as the capture began, one as it finished")
        XCTAssertEqual(scheduler.liveTimers.count, 0)
        service.end()
        XCTAssertNil(service.state)
    }

    // MARK: - At rest

    private let heldAtRest = [
        TimedReport(bytes: [0x01, 0x80], uptimeNs: 9_000_000_000),
        TimedReport(bytes: [0x01, 0x80], uptimeNs: 9_004_000_000)
    ]

    func testMovingOnFromTheFirstStepTakesTheReportsAtRestOnTheWallClock() throws {
        service.begin(deviceKey: "1234:5678")
        try XCTUnwrap(capture.events).found(device)
        drainMain()
        capture.holdAtRest(heldAtRest)
        service.send(.next)
        XCTAssertEqual(service.state?.capture.rest, [
            RestReport(atMs: 1_763_585_999_000, bytes: [0x01, 0x80]),
            RestReport(atMs: 1_763_585_999_004, bytes: [0x01, 0x80])
        ])
        capture.holdAtRest([TimedReport(bytes: [0x02], uptimeNs: 9_900_000_000)])
        service.send(.next)
        XCTAssertEqual(service.state?.capture.rest.count, 2, "only the first step's reports are at rest")
    }

    func testSkippingTheFirstStepTakesNoReportsAtRest() throws {
        service.begin(deviceKey: "1234:5678")
        try XCTUnwrap(capture.events).found(device)
        drainMain()
        capture.holdAtRest(heldAtRest)
        service.send(.skip)
        XCTAssertEqual(service.state?.capture.rest, [])
    }

    func testTheFinishedCaptureCarriesItInUsbDescriptorsTerms() throws {
        service.begin(deviceKey: "1234:5678")
        try XCTUnwrap(capture.events).found(device)
        drainMain()
        capture.holdAtRest(heldAtRest)
        for _ in SupportStep.allCases {
            service.send(.next)
        }
        let finished = try XCTUnwrap(service.lastFinished)
        XCTAssertEqual(finished.capture?.restReports.count, 2)
        XCTAssertEqual(finished.capture?.product, "Pad")
        XCTAssertEqual(finished.report.hasPrefix("Controller support capture"), true, "the text for an issue stays")
    }

    func testAPostFromACaptureThatEndedLandsNowhere() throws {
        service.begin(deviceKey: "1234:5678")
        let stale = try XCTUnwrap(capture.events)
        service.begin(deviceKey: "named:Other")
        stale.found(device)
        drainMain()
        XCTAssertEqual(service.state?.capture.phase, .searching)
        XCTAssertEqual(capture.targets.last, .named("Other"))
    }

    // MARK: - Which device

    func testAUsbTargetIsMatchedByIOKitAndANameAmongTheGameUsages() {
        let byIds = supportMatching(.usb(vendorId: 0x1234, productId: 0x5678))
        XCTAssertEqual(byIds.count, 1)
        XCTAssertEqual(byIds.first?[kIOHIDVendorIDKey] as? Int, 0x1234)
        XCTAssertEqual(byIds.first?[kIOHIDGCSyntheticDeviceKey] as? Bool, false)
        XCTAssertEqual(supportMatching(.named("Pad")).count, hidCensusMatching().count)
    }

    func testTheDeviceIsReadOnlyWhenItIsTheOneNamed() {
        let properties: [String: Any] = [
            kIOHIDVendorIDKey: 0x1234, kIOHIDProductIDKey: 0x5678, kIOHIDProductKey: " Pad ", kIOHIDManufacturerKey: "Maker",
            kIOHIDTransportKey: "USB", kIOHIDReportDescriptorKey: Data([0x05, 0x01])
        ]
        let read = supportDevice(properties, target: .usb(vendorId: 0x1234, productId: 0x5678))
        XCTAssertEqual(read?.descriptor, [0x05, 0x01])
        XCTAssertEqual(read?.manufacturer, "Maker")
        XCTAssertNotNil(supportDevice(properties, target: .named("pad")), "a name matches trimmed and in any case")
        XCTAssertNil(supportDevice(properties, target: .named("Other")))
        XCTAssertNil(supportDevice(properties, target: .usb(vendorId: 0x1234, productId: 1)))
        var synthetic = properties
        synthetic[kIOHIDGCSyntheticDeviceKey] = true
        XCTAssertNil(supportDevice(synthetic, target: .named("Pad")), "never the device macOS synthesises")
    }

    func testTheDeviceIsDescribedByIOKitsOwnKeysInAFixedOrderAndNeverItsSerialNumber() {
        let hid: [String: Any] = [
            kIOHIDTransportKey: "USB", kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6, kIOHIDVersionNumberKey: 0x0100,
            kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x05, kIOHIDMaxInputReportSizeKey: 64,
            kIOHIDReportIntervalKey: 4000, kIOHIDSerialNumberKey: "SERIAL-HID"
        ]
        let usb: [String: Any] = [
            "bcdUSB": 0x0200, "bDeviceClass": 0, "bMaxPacketSize0": 64, "iManufacturer": 1, "iProduct": 2,
            "iSerialNumber": 3, "kUSBSerialNumberString": "SERIAL-USB", "USB Serial Number": "SERIAL-USB"
        ]
        let facts = supportDeviceFacts(hid: hid, usbDevice: usb)
        XCTAssertEqual(facts.map(\.key), [
            "Transport", "VendorID", "ProductID", "VersionNumber", "PrimaryUsagePage", "PrimaryUsage", "MaxInputReportSize",
            "ReportInterval", "bcdUSB", "bDeviceClass", "bMaxPacketSize0", "iManufacturer", "iProduct"
        ])
        XCTAssertEqual(facts.map(\.value), ["USB", "054c", "0ce6", "0100", "0001", "0005", "64", "4000", "0200", "00", "64", "1", "2"])
        let text = facts.map(\.value).joined()
        XCTAssertFalse(text.contains("SERIAL"))
    }

    func testABluetoothDeviceIsDescribedByItsHidPropertiesAlone() {
        let hid: [String: Any] = [kIOHIDTransportKey: "Bluetooth", kIOHIDVendorIDKey: 0x054C, kIOHIDVendorIDSourceKey: 2]
        XCTAssertEqual(supportDeviceFacts(hid: hid, usbDevice: nil).map(\.key), ["Transport", "VendorID", "VendorIDSource"])
    }

    func testTheDeviceReadForTheCaptureCarriesItsInterfaceAndItsFacts() {
        let properties: [String: Any] = [
            kIOHIDVendorIDKey: 0x1234, kIOHIDProductIDKey: 0x5678, kIOHIDProductKey: "Pad", kIOHIDTransportKey: "USB",
            hidInterfaceNumberKey: 2
        ]
        let read = supportDevice(properties, target: .usb(vendorId: 0x1234, productId: 0x5678), usbDevice: ["bcdUSB": 0x0110])
        XCTAssertEqual(read?.interfaceNumber, 2)
        XCTAssertEqual(read?.facts.last, SupportDeviceFact(key: "bcdUSB", value: "0110"))
        XCTAssertTrue(supportPropertyKeys.contains(hidInterfaceNumberKey))
        XCTAssertFalse(supportPropertyKeys.contains(kIOHIDSerialNumberKey), "the serial number is never read")
        XCTAssertFalse(supportUsbDeviceKeys.contains("iSerialNumber"))
        XCTAssertFalse(supportUsbDeviceKeys.contains("kUSBSerialNumberString"))
    }

    func testEachPropertyIsAskedForOnce() {
        XCTAssertEqual(Set(supportPropertyKeys).count, supportPropertyKeys.count, "the properties are keyed uniquely")
        XCTAssertTrue(supportPropertyKeys.contains(kIOHIDMaxInputReportSizeKey))
        XCTAssertTrue(supportPropertyKeys.contains(kIOHIDVendorIDKey))
    }

    // MARK: - The ring

    private func write(_ ring: HidReportRing, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ring.write($0) }
    }

    func testTheRingDrainsOldestFirstAndSkipsARepeat() {
        let ring = HidReportRing()
        write(ring, [1])
        write(ring, [1])
        write(ring, [2, 2])
        XCTAssertEqual(ring.drain(), [[1], [2, 2]])
        XCTAssertEqual(ring.drain(), [])
        write(ring, [2, 2])
        XCTAssertEqual(ring.drain(), [], "the last report is still the last after a drain")
    }

    func testTheRingKeepsTheFirstTwentyReportsAtRestRepeatsAndTimesIncluded() {
        let ring = HidReportRing()
        for index in 0 ..< 25 {
            [UInt8(0x01)].withUnsafeBufferPointer { ring.write($0, uptimeNs: UInt64(index)) }
        }
        let held = ring.restReports()
        XCTAssertEqual(held.count, 20)
        XCTAssertEqual(held.map(\.uptimeNs), (0 ..< 20).map(UInt64.init))
        XCTAssertEqual(Set(held.map(\.bytes)), [[0x01]], "a repeat at rest is a report at rest")
        XCTAssertEqual(ring.drain(), [[0x01]], "the steps still see each report once")
    }

    func testARestartedRingHoldsNoReportsAtRest() {
        let ring = HidReportRing()
        write(ring, [1])
        ring.restart()
        XCTAssertEqual(ring.restReports(), [])
        XCTAssertEqual(ring.drain(), [], "and none for the steps")
        write(ring, [1])
        XCTAssertEqual(ring.drain(), [[1]], "the last report of the capture that ended is not this one's last")
    }

    func testAFullRingOverwritesItsOldestAndKeepsALongReportsFirstBytes() {
        let ring = HidReportRing()
        for value in 0 ..< HidReportRing.slotCount + 3 {
            write(ring, [UInt8(value)])
        }
        let drained = ring.drain()
        XCTAssertEqual(drained.count, HidReportRing.slotCount)
        XCTAssertEqual(drained.first, [3])
        write(ring, [UInt8](repeating: 7, count: HidReportRing.slotBytes + 10))
        XCTAssertEqual(ring.drain().first?.count, HidReportRing.slotBytes)
    }
}
