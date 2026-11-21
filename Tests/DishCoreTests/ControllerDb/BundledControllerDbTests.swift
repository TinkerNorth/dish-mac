// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The copy the app ships, read through the same decoder, and the Mac's own
/// Direct table checked against it: the table stays the policy, the data
/// must agree with it on every family both name.
final class BundledControllerDbTests: XCTestCase {

    private func bundled() throws -> ControllerDbSet {
        try XCTUnwrap(BundledControllerDb.load(), "the bundled copy verifies against its own manifest")
    }

    func testTheBundledCopyIsVersionOneWithEveryRecord() throws {
        let set = try bundled()
        XCTAssertEqual(set.dbVersion, 1)
        XCTAssertEqual(set.database.records.count, 272)
        XCTAssertEqual(set.manifest.files.count, 7, "the records and the six locales")
    }

    func testEveryLocaleShipsAndEnglishNamesEveryRecord() throws {
        let set = try bundled()
        XCTAssertEqual(Set(set.strings.tables.keys), Set(ControllerStrings.locales))
        let unnamed = set.database.records.filter { set.strings.controllerName($0.id, locale: "en") == nil }.map(\.id)
        XCTAssertEqual(unnamed, [])
    }

    func testEveryIssueHasATitleAndABodyInEnglish() throws {
        let set = try bundled()
        let issues = set.database.records.flatMap(\.issues).map(\.id)
        XCTAssertFalse(issues.isEmpty)
        for id in issues {
            XCTAssertNotNil(set.strings.issueTitle(id, locale: "en"), id)
            XCTAssertNotNil(set.strings.issueBody(id, locale: "en"), id)
        }
    }

    /// Every row the Mac reads by its own table has a record for the same
    /// identity whose family is the row's decoder, and a HID row's button
    /// order is the record's mapping.
    func testEveryDirectModelHasARecordOfItsOwnFamily() throws {
        let index = try ControllerIndex(bundled(), source: .bundled)
        for model in directModels {
            let key = usbPathKey(vendorId: model.vendorId, productId: model.productId)
            let record = try XCTUnwrap(index.record(vendorId: model.vendorId, productId: model.productId), "\(key) has a record")
            XCTAssertEqual(record.family, controllerFamily(of: model.decoder), "\(key): \(model.name)")
            guard case let .hidGamepad(order) = model.decoder else { continue }
            XCTAssertEqual(record.mapping, controllerMapping(of: order), "\(key)'s button order")
        }
    }

    /// The reverse, for every family the Mac's table reads whole: a record of
    /// it is a row of the table or an identity the Mac declines. The table
    /// covers the Xbox 360 family in part; the data's other rows of it reach
    /// the XUSB reader as served rows.
    func testEveryRecordOfAFamilyTheTableReadsWholeIsARowOrDeclined() throws {
        let tableFamilies = macCompiledFamilies.subtracting([.xinput360])
        for record in try bundled().database.records where record.family.map(tableFamilies.contains) == true {
            for identity in record.usb + record.bluetooth {
                let (vendorId, productId) = try XCTUnwrap(parseUsbPathKey(identity))
                let row = directModel(vendorId: vendorId, productId: productId)
                let declined = directIdentityDeclined(vendorId: vendorId, productId: productId)
                XCTAssertTrue(row != nil || declined, "\(record.id) (\(identity)) is neither a row nor declined")
            }
        }
    }

    func testEveryDeclinedIdentityIsNotARow() {
        for identity in declinedDirectIdentities {
            XCTAssertNil(directModel(vendorId: identity.vendorId, productId: identity.productId))
        }
    }

    func testTheBundledCopyAddsTheAutoXbox360RowsAndNothingElse() throws {
        let set = try bundled()
        let served = ServedDirectModels(index: ControllerIndex(set, source: .bundled))
        XCTAssertEqual(served.matchedByIdentity, [], "no opt-in row is served")
        XCTAssertNil(served.model(vendorId: 0x057E, productId: 0x200E), "the charging grip stays with macOS")
        let autoXbox360 = set.database.records.filter { $0.family == .xinput360 && $0.directRule == .auto }.flatMap(\.usb)
        let expected = try autoXbox360.compactMap { identity -> String? in
            let (vendorId, productId) = try XCTUnwrap(parseUsbPathKey(identity))
            let compiled = directModel(vendorId: vendorId, productId: productId) != nil
            return compiled || directIdentityDeclined(vendorId: vendorId, productId: productId) ? nil : identity
        }
        XCTAssertEqual(expected.count, 43, "45 auto rows, less the table's Ultimate 2 and macOS's own 045e:028e")
        for identity in expected {
            let (vendorId, productId) = try XCTUnwrap(parseUsbPathKey(identity))
            XCTAssertEqual(served.model(vendorId: vendorId, productId: productId)?.decoder, .xusb, identity)
        }
    }
}
