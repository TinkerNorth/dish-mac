// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest
@testable import Dish

/// The app reads its words from the resource bundle in its own
/// `Contents/Resources`, so a Mac with no build tree on it still finds them.
final class ResourceBundleTests: XCTestCase {

    private var resources: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        resources = FileManager.default.temporaryDirectory.appendingPathComponent("dish-resources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: resources)
        try super.tearDownWithError()
    }

    func testTheBundleInTheAppsResourcesIsTheOneRead() throws {
        let shipped = resources.appendingPathComponent(ResourceBundle.name, isDirectory: true)
        try FileManager.default.createDirectory(at: shipped, withIntermediateDirectories: true)
        let found = try XCTUnwrap(ResourceBundle.inside(resources))
        XCTAssertEqual(found.bundleURL.standardizedFileURL, shipped.standardizedFileURL)
    }

    func testResourcesWithoutTheBundleOfferNone() {
        XCTAssertNil(ResourceBundle.inside(resources))
    }

    func testNoResourcesOfferNone() {
        XCTAssertNil(ResourceBundle.inside(nil))
    }

    func testTheNameIsTheBundleSwiftPMBuildsForTheAppTarget() {
        XCTAssertEqual(Bundle.module.bundleURL.lastPathComponent, ResourceBundle.name)
    }

    func testOutsideAnAppTheWordsStillLoad() {
        XCTAssertEqual(L10n.app.scan, "Scan")
    }
}
