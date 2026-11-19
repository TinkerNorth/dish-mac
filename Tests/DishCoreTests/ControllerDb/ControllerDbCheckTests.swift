// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The check's decisions: whether to ask at all, what the manifest's answer
/// means, and whether the downloaded files may replace the cache.
final class ControllerDbCheckTests: XCTestCase {

    func testTheScheduleIsTenSecondsThenEverySixHours() {
        XCTAssertEqual(ControllerDbSchedule.firstCheckDelayMs, 10000)
        XCTAssertEqual(ControllerDbSchedule.intervalMs, 21_600_000)
        XCTAssertEqual(ControllerDbSchedule.baseURLString, "https://dish.tinkernorth.com/controllers/v1/")
    }

    func testWithTheSwitchOffNothingIsAskedAndTheResultIsOff() {
        XCTAssertEqual(controllerDbGate(checksEnabled: false), .stay(.off))
        XCTAssertEqual(controllerDbGate(checksEnabled: true), .ask)
    }

    func testNotModifiedIsUpToDate() {
        XCTAssertEqual(manifestStep(.notModified, activeVersion: 1), .done(.upToDate))
    }

    func testNoAnswerIsOffline() {
        XCTAssertEqual(manifestStep(.unreachable, activeVersion: 1), .done(.offline))
    }

    func testABodyThatIsNotAManifestIsInvalid() {
        XCTAssertEqual(manifestStep(.body(Data("<html>".utf8), etag: nil), activeVersion: 1), .done(.invalid))
    }

    func testAnEqualOrOlderVersionIsUpToDate() throws {
        let published = try PublishedSet(dbVersion: 2)
        XCTAssertEqual(manifestStep(.body(published.manifestData, etag: "e"), activeVersion: 2), .done(.upToDate))
        XCTAssertEqual(manifestStep(.body(published.manifestData, etag: "e"), activeVersion: 3), .done(.upToDate))
    }

    func testANewerVersionIsDownloaded() throws {
        let published = try PublishedSet(dbVersion: 2)
        XCTAssertEqual(manifestStep(.body(published.manifestData, etag: nil), activeVersion: 1), .download(published.manifest))
    }

    func testFilesThatDidNotAllArriveAreOffline() throws {
        XCTAssertEqual(try installStep(manifest: PublishedSet(dbVersion: 2).manifest, files: nil), .done(.offline))
    }

    func testFilesThatDoNotVerifyAreInvalid() throws {
        let published = try PublishedSet(dbVersion: 2)
        var files = published.files
        files[ControllerDbFiles.controllers] = Data("{}".utf8)
        XCTAssertEqual(installStep(manifest: published.manifest, files: files), .done(.invalid))
    }

    func testFilesThatVerifyAreInstalledWhole() throws {
        let published = try PublishedSet(dbVersion: 2)
        let set = try XCTUnwrap(published.set)
        XCTAssertEqual(installStep(manifest: published.manifest, files: published.files), .install(set, files: published.files))
    }
}
