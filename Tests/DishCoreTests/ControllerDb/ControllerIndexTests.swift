// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The index from `vid:pid` to record, and which set it is built from.
final class ControllerIndexTests: XCTestCase {

    private func set(_ dbVersion: Int, _ records: [[String: Any]]) throws -> ControllerDbSet {
        try XCTUnwrap(try PublishedSet(dbVersion: dbVersion, records: records).set)
    }

    private let blePad = RecordFixture().with(["id"], "ble-pad").with(["identity"], ["usb": ["1234:0001"], "bluetooth": ["1234:0002"]])

    func testAPadIsFoundByItsUsbIdentity() throws {
        let index = try ControllerIndex(set(1, [RecordFixture().json]), source: .bundled)
        XCTAssertEqual(index.record(vendorId: 0x054C, productId: 0x0CE6)?.id, "sony-dualsense")
        XCTAssertNil(index.record(vendorId: 0x054C, productId: 0x0CE7))
    }

    func testABluetoothIdentityIsFoundOnBluetoothAndWhenTheTransportIsUnknown() throws {
        let index = try ControllerIndex(set(1, [blePad.json]), source: .bundled)
        XCTAssertEqual(index.record(vendorId: 0x1234, productId: 0x0002, transport: .bluetooth)?.id, "ble-pad")
        XCTAssertEqual(index.record(vendorId: 0x1234, productId: 0x0002)?.id, "ble-pad")
        XCTAssertEqual(index.record(vendorId: 0x1234, productId: 0x0001, transport: .bluetooth)?.id, "ble-pad", "the other list next")
    }

    func testTheFirstRecordToNameAnIdKeepsIt() throws {
        let second = RecordFixture().with(["id"], "second")
        let index = try ControllerIndex(set(1, [RecordFixture().json, second.json]), source: .bundled)
        XCTAssertEqual(index.record(vendorId: 0x054C, productId: 0x0CE6)?.id, "sony-dualsense")
    }

    func testTheIndexListsEveryIdentityUsbFirst() throws {
        let index = try ControllerIndex(set(1, [blePad.json]), source: .bundled)
        XCTAssertEqual(index.identities, ["1234:0001", "1234:0002"])
    }

    func testANewerCacheIsTheSetInForce() throws {
        let active = try activeControllerIndex(bundled: set(1, [RecordFixture().json]), cached: set(2, [blePad.json]))
        XCTAssertEqual(active.dbVersion, 2)
        XCTAssertEqual(active.source, .cache)
        XCTAssertNil(active.record(vendorId: 0x054C, productId: 0x0CE6), "a newer version replaces the whole set")
    }

    func testACacheNoNewerThanTheBundledCopyIsIgnored() throws {
        let bundled = try set(2, [RecordFixture().json])
        XCTAssertEqual(try activeControllerIndex(bundled: bundled, cached: set(2, [blePad.json])).source, .bundled)
        XCTAssertEqual(try activeControllerIndex(bundled: bundled, cached: set(1, [blePad.json])).source, .bundled)
        XCTAssertEqual(activeControllerIndex(bundled: bundled, cached: nil).dbVersion, 2)
    }
}
