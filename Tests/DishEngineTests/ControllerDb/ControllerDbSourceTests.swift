// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The check against the website over a recording gateway: nothing leaves
/// the Mac with the switch off, 304 and an equal version are up to date, a
/// newer version is downloaded, verified and swapped in whole, and every
/// failure leaves the data in force as it was.
@MainActor
final class ControllerDbSourceTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var gateway: RecordingControllerDbGateway!
    private var preferences: ControllerDbPreferenceStore!
    private var nowMs: Int64 = 1_763_586_000_000

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        directory = scratchDirectory()
        gateway = RecordingControllerDbGateway()
        preferences = ControllerDbPreferenceStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func source(bundledVersion: Int = 1) throws -> ControllerDbSource {
        let bundled = try XCTUnwrap(try ServedVersion(dbVersion: bundledVersion, recordId: "bundled-pad", usb: "1111:2222").set)
        return ControllerDbSource(
            bundled: bundled,
            cache: ControllerDbCache(directory: directory),
            gateway: gateway,
            preferences: preferences
        ) { [weak self] in self?.nowMs ?? 0 }
    }

    private func check(_ source: ControllerDbSource) async {
        source.checkNow()
        await source.settle()
    }

    // MARK: - The switch

    func testTheSwitchIsOnByDefault() throws {
        XCTAssertTrue(try source().state.checksEnabled)
    }

    func testWithTheSwitchOffNoRequestLeavesTheMac() async throws {
        preferences.setChecksEnabled(false)
        let source = try source()
        source.start()
        XCTAssertNil(source.pendingCheckDelayMs, "nothing is armed")
        await check(source)
        source.firePendingCheck()
        await source.settle()
        XCTAssertEqual(gateway.requests, [])
        XCTAssertEqual(source.state.lastCheckResult, .off)
        XCTAssertEqual(source.state.lastCheckAtMs, nowMs)
    }

    func testTurningTheSwitchOffDisarmsTheSchedule() throws {
        let source = try source()
        source.start()
        XCTAssertEqual(source.pendingCheckDelayMs, ControllerDbSchedule.firstCheckDelayMs)
        preferences.setChecksEnabled(false)
        XCTAssertNil(source.pendingCheckDelayMs)
        XCTAssertFalse(source.state.checksEnabled)
        preferences.setChecksEnabled(true)
        XCTAssertEqual(source.pendingCheckDelayMs, ControllerDbSchedule.firstCheckDelayMs)
    }

    func testTheFirstCheckIsTenSecondsAfterLaunchThenEverySixHours() async throws {
        let source = try source()
        source.start()
        XCTAssertEqual(source.pendingCheckDelayMs, 10000)
        XCTAssertEqual(gateway.requests, [], "nothing at launch itself")
        source.firePendingCheck()
        await source.settle()
        XCTAssertEqual(gateway.requests, [.manifest(etag: nil)])
        XCTAssertEqual(source.pendingCheckDelayMs, 21_600_000)
        source.stop()
    }

    // MARK: - The answers

    func testNotModifiedIsUpToDateAndTheETagRidesTheNextRequest() async throws {
        let served = try ServedVersion(dbVersion: 1)
        gateway.manifest = .body(served.manifestData, etag: "\"v1\"")
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .upToDate)
        gateway.manifest = .notModified
        await check(source)
        XCTAssertEqual(gateway.requests.last, .manifest(etag: "\"v1\""))
        XCTAssertEqual(source.state.lastCheckResult, .upToDate)
        XCTAssertFalse(gateway.requests.contains(.file(ControllerDbFiles.controllers)), "an equal version downloads nothing")
    }

    func testNoAnswerIsOfflineAndTheDataStays() async throws {
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .offline)
        XCTAssertEqual(source.index.state.source, .bundled)
        XCTAssertFalse(source.state.checking)
    }

    func testANewerVersionIsDownloadedVerifiedAndSwappedInWhole() async throws {
        let served = try ServedVersion(dbVersion: 2)
        gateway.manifest = .body(served.manifestData, etag: "\"v2\"")
        gateway.files = served.files
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .updated)
        XCTAssertEqual(source.state.activeVersion, 2)
        XCTAssertEqual(source.state.source, .cache)
        XCTAssertEqual(source.index.state.record(vendorId: 0x1234, productId: 0x5678)?.id, "served-pad")
        XCTAssertNil(source.index.state.record(vendorId: 0x1111, productId: 0x2222), "the whole set is replaced")
        XCTAssertEqual(try self.source().index.state.dbVersion, 2, "the next launch starts from the cache")
    }

    func testAFileThatDoesNotVerifyIsInvalidAndTheDataStays() async throws {
        let served = try ServedVersion(dbVersion: 2)
        gateway.manifest = .body(served.manifestData, etag: nil)
        gateway.files = served.files
        gateway.files[ControllerDbFiles.controllers] = Data("{}".utf8)
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .invalid)
        XCTAssertEqual(source.index.state.source, .bundled)
        XCTAssertNil(ControllerDbCache(directory: directory).load())
    }

    func testAFileThatDoesNotArriveIsOffline() async throws {
        let served = try ServedVersion(dbVersion: 2)
        gateway.manifest = .body(served.manifestData, etag: nil)
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .offline)
        XCTAssertEqual(source.index.state.dbVersion, 1)
    }

    func testABodyThatIsNotAManifestIsInvalid() async throws {
        gateway.manifest = .body(Data("<html>".utf8), etag: nil)
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .invalid)
    }

    func testAManifestNamingAPathOutsideTheCacheIsInvalidAndNothingIsRequestedOrWritten() async throws {
        let escape = "../../escaped.txt"
        let outside = directory.appendingPathComponent(escape).standardizedFileURL
        defer { try? FileManager.default.removeItem(at: outside) }
        let served = try ServedVersion(dbVersion: 2)
        var files = served.files
        files[escape] = Data("written outside the cache".utf8)
        let entries = files.mapValues { ["sha256": sha256Hex($0), "bytes": $0.count] as [String: Any] }
        let manifest = try JSONSerialization.data(withJSONObject: ["schema": 1, "dbVersion": 2, "files": entries])
        gateway.manifest = .body(manifest, etag: nil)
        gateway.files = files
        let source = try source()
        await check(source)
        XCTAssertEqual(source.state.lastCheckResult, .invalid)
        XCTAssertEqual(gateway.requests, [.manifest(etag: nil)], "no file is requested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(source.index.state.source, .bundled)
    }

    func testACacheNoNewerThanTheBundledCopyIsNotInForce() throws {
        let served = try ServedVersion(dbVersion: 1)
        var files = served.files
        files[ControllerDbFiles.manifest] = served.manifestData
        XCTAssertTrue(ControllerDbCache(directory: directory).replaceAll(files))
        XCTAssertEqual(try source(bundledVersion: 1).index.state.source, .bundled)
    }

    func testTheLastCheckIsRememberedAcrossLaunches() async throws {
        let first = try source()
        await check(first)
        let next = try source()
        XCTAssertEqual(next.state.lastCheckResult, .offline)
        XCTAssertEqual(next.state.lastCheckAtMs, nowMs)
    }

    // MARK: - The wire

    func testAStatusOtherThan200Or304IsNoAnswer() {
        XCTAssertEqual(manifestReply(status: 304, body: Data(), etag: nil), .notModified)
        XCTAssertEqual(manifestReply(status: 200, body: Data("x".utf8), etag: "e"), .body(Data("x".utf8), etag: "e"))
        XCTAssertEqual(manifestReply(status: 403, body: Data("x".utf8), etag: nil), .unreachable)
    }

    func testTheRequestCarriesNoCookiesAndNoCacheOfItsOwn() {
        let configuration = ControllerDbHTTPClient.ephemeral().configuration
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }
}
