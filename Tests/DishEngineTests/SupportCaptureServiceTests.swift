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

    override func setUp() {
        super.setUp()
        capture = FakeHidReportCapture()
        scheduler = ManualPathScheduler()
        service = SupportCaptureService(capture: capture, scheduler: scheduler)
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
