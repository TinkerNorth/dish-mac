// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// One record per IORegistry entry: IOHIDManager hands back a separate
/// reference for every matching rule a device satisfies, so a pad that
/// matches a model rule and the gamepad rule arrives twice, and the reader
/// must still read it once and end it once.
final class HidEntryRegistryTests: XCTestCase {
    private let n64 = UInt64(0x1_0038_4414)
    private let pro = UInt64(0x1_0038_4443)

    func testASecondReferenceToTheSameDeviceKeepsTheFirstEntry() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "hid:057e:2019")
        registry.file(n64, "hid:057e:2019#1")
        XCTAssertEqual(registry.reading, ["hid:057e:2019"])
    }

    func testADeviceIsKnownFromItsFirstReference() {
        var registry = HidEntryRegistry<String>()
        XCTAssertFalse(registry.knows(n64))
        registry.file(n64, "hid:057e:2019")
        XCTAssertTrue(registry.knows(n64))
    }

    func testARemovalEndsTheDeviceOnceAndItsSecondReferenceEndsNothing() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "hid:057e:2019")
        XCTAssertEqual(registry.remove(n64), "hid:057e:2019")
        XCTAssertNil(registry.remove(n64))
        XCTAssertEqual(registry.reading, [])
    }

    func testTwoDevicesAreTwoEntriesInRegistryOrder() {
        var registry = HidEntryRegistry<String>()
        registry.file(pro, "pro")
        registry.file(n64, "n64")
        XCTAssertEqual(registry.reading, ["n64", "pro"])
    }

    func testReconcileForgetsOnlyTheDevicesMacOSNoLongerLists() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "n64")
        registry.file(pro, "pro")
        let gone = registry.reconcile(present: [pro])
        XCTAssertEqual(gone, ["n64"])
        XCTAssertEqual(registry.reading, ["pro"])
        XCTAssertFalse(registry.knows(n64))
    }

    func testReconcileWithEveryDevicePresentEndsNothing() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "n64")
        XCTAssertEqual(registry.reconcile(present: [n64, pro]), [])
        XCTAssertEqual(registry.reading, ["n64"])
    }

    func testAReleasedDeviceIgnoresALateReferenceUntilItLeaves() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "hid:2dc8:5006")
        XCTAssertEqual(registry.release { $0 == "hid:2dc8:5006" }, "hid:2dc8:5006")
        registry.file(n64, "late")
        XCTAssertEqual(registry.reading, [])
        XCTAssertTrue(registry.knows(n64))
        XCTAssertNil(registry.remove(n64))
        registry.file(n64, "again")
        XCTAssertEqual(registry.reading, ["again"])
    }

    func testReleasingASlotNoEntryReadsReleasesNothing() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "n64")
        XCTAssertNil(registry.release { $0 == "other" })
        XCTAssertEqual(registry.reading, ["n64"])
    }

    func testReconcileForgetsAReleasedDeviceWithoutALaneToClose() {
        var registry = HidEntryRegistry<String>()
        registry.file(n64, "n64")
        XCTAssertEqual(registry.release { $0 == "n64" }, "n64")
        XCTAssertEqual(registry.reconcile(present: []), [])
        XCTAssertFalse(registry.knows(n64))
    }
}
