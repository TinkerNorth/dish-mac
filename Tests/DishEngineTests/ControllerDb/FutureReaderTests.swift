// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// A dbVersion 2 from the future, served byte for byte to the production
/// check with the bundled dbVersion 1 in force: a reader released today
/// takes it, and no record's trouble costs another record. The fixture is
/// dish-website's future-reader set; its EXPECT.md is the table these follow.
@MainActor
final class FutureReaderTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var gateway: RecordingControllerDbGateway!

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        directory = scratchDirectory()
        gateway = RecordingControllerDbGateway()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// The check run once against the served set.
    private func checked() async throws -> ControllerDbSource {
        let fixture = try FutureReaderFixture()
        gateway.manifest = .body(fixture.manifest, etag: "\"future\"")
        gateway.files = fixture.files
        let bundled = try XCTUnwrap(BundledControllerDb.load())
        let source = ControllerDbSource(
            bundled: bundled,
            cache: ControllerDbCache(directory: directory),
            gateway: gateway,
            preferences: ControllerDbPreferenceStore(defaults: defaults)
        )
        source.checkNow()
        await source.settle()
        return source
    }

    private func record(_ source: ControllerDbSource, _ vendorId: UInt16, _ productId: UInt16) -> ControllerRecord? {
        source.index.state.record(vendorId: vendorId, productId: productId)
    }

    // MARK: - The whole set

    func testTheCheckEndsUpdatedAndVersion2ReplacesVersion1Whole() async throws {
        let source = try await checked()
        XCTAssertEqual(source.state.lastCheckResult, .updated)
        XCTAssertEqual(source.state.activeVersion, 2)
        XCTAssertEqual(source.index.state.source, .cache)
        let bundledOnly = try XCTUnwrap(BundledControllerDb.load()).database.records.first { $0.usb == ["057e:2009"] }
        XCTAssertNotNil(bundledOnly, "version 1 names the Switch Pro Controller")
        XCTAssertNil(record(source, 0x057E, 0x2009), "version 2 does not, and records are never merged")
    }

    func testTheManifestsUnknownSignatureIsIgnored() throws {
        let fixture = try FutureReaderFixture()
        XCTAssertTrue(try XCTUnwrap(String(bytes: fixture.manifest, encoding: .utf8)).contains("\"signature\""))
        XCTAssertEqual(try decodeControllerDbManifest(fixture.manifest).get().dbVersion, 2)
    }

    func testALocaleTheBuildDoesNotShipIsStoredAndNothingElseIsWritten() async throws {
        let source = try await checked()
        XCTAssertFalse(ControllerStrings.locales.contains("it"))
        let fixture = try FutureReaderFixture()
        let stored = ControllerDbCache(directory: directory).files()
        XCTAssertEqual(Set(stored.keys), Set(fixture.files.keys).union([ControllerDbFiles.manifest]))
        XCTAssertEqual(stored[ControllerDbFiles.strings("it")], fixture.files[ControllerDbFiles.strings("it")])
        XCTAssertEqual(source.index.state.strings.controllerName("future-pad-served", locale: "it"), "Future Pad (served)")
    }

    func testTheDatabasesUnknownGeneratedByIsIgnored() throws {
        let fixture = try FutureReaderFixture()
        let body = try XCTUnwrap(fixture.files[ControllerDbFiles.controllers])
        XCTAssertTrue(try XCTUnwrap(String(bytes: body, encoding: .utf8)).contains("\"generatedBy\""))
        XCTAssertEqual(try decodeControllerDatabase(body).get().dbVersion, 2)
    }

    func testEveryRecordIsAccountedForAndNoneCostsAnother() async throws {
        let source = try await checked()
        let kept = [
            "sony-dualsense", "xbox-360-controller", "future-pad-served", "future-pad-served-ds4",
            "future-pad-new-family", "future-pad-new-op", "valve-steam-controller-bluetooth"
        ]
        let ids = Set(source.index.state.identities.compactMap { key in
            parseUsbPathKey(key).flatMap { record(source, $0.0, $0.1)?.id }
        })
        XCTAssertEqual(ids, Set(kept), "the two this reader cannot hold, the mapping object and the misauthored row, are left out alone")
    }

    // MARK: - Record by record

    func testTheDualSenseIsAsUsableAsInVersion1AndKeepsBothIssues() async throws {
        let source = try await checked()
        let served = try XCTUnwrap(record(source, 0x054C, 0x0CE6))
        let bundled = try XCTUnwrap(BundledControllerDb.load()).database.records.first { $0.id == "sony-dualsense" }
        XCTAssertEqual(served.familyId, bundled?.familyId)
        XCTAssertEqual(served.inputCapabilities, bundled?.inputCapabilities)
        XCTAssertEqual(served.outputCapabilities, bundled?.outputCapabilities)
        XCTAssertEqual(served.issues.map(\.id), ["thor-ds5-rumble-usb", "future-os-as-text"])
    }

    func testAnOsGivenAsTextMatchesByItsMajorVersionAndAnotherPlatformsKeyDoesNot() async throws {
        let source = try await checked()
        let issues = try XCTUnwrap(record(source, 0x054C, 0x0CE6)).issues
        let onTheMac = IssueHost(model: "Future Handheld", osMajor: 26)
        let onAnOlderMac = IssueHost(model: "Future Handheld", osMajor: 15)
        XCTAssertEqual(issuesApplying(issues, transport: .usb, host: onTheMac).map(\.id), ["future-os-as-text"], "\"26.1\" is 26")
        XCTAssertEqual(issuesApplying(issues, transport: .usb, host: onAnOlderMac), [], "Android's \"15\" is not macOS 15")
    }

    /// The Mac's own row for Microsoft's Xbox 360 Controller hands it to
    /// macOS, whose driver reads it; the served record changes none of that.
    func testTheXbox360RecordNeedingAFutureFamilyIsInertAndTheBuildsRowStillReadsThePad() async throws {
        let source = try await checked()
        let served = try XCTUnwrap(record(source, 0x045E, 0x028E))
        XCTAssertTrue(recordIsInert(served))
        XCTAssertTrue(directIdentityDeclined(vendorId: 0x045E, productId: 0x028E))
        XCTAssertNil(directModel(vendorId: 0x045E, productId: 0x028E, served: ServedDirectModels(index: source.index.state)))
    }

    /// On the Mac the Xbox 360 one (`xinput360`) is the family the XUSB
    /// reader runs, so it resolves to its served record under the Mac's own
    /// rule; the DualShock 4 one (`dualshock4`) is a family no Mac reader
    /// runs, so it is inert, named and never applied.
    func testOfTheTwoServedOnlyPadsTheXinput360OneResolvesAndTheDualShock4OneIsInert() async throws {
        let source = try await checked()
        let served = ServedDirectModels(index: source.index.state)
        let xinput = try XCTUnwrap(served.model(vendorId: 0x1209, productId: 0x0F02))
        XCTAssertEqual(xinput.decoder, .xusb)
        XCTAssertEqual(record(source, 0x1209, 0x0F02)?.directRule, .whenOsCannot, "the Mac's rule is read first")
        XCTAssertEqual(xinput.rule, .whenMacOSCannot)
        XCTAssertTrue(xusbReads(vendorId: 0x1209, productId: 0x0F02, served: served))
        let ds4 = try XCTUnwrap(record(source, 0x1209, 0x0F05))
        XCTAssertTrue(recordIsInert(ds4))
        XCTAssertNil(served.model(vendorId: 0x1209, productId: 0x0F05))
        XCTAssertEqual(source.index.state.strings.controllerName(ds4.id, locale: "en"), "Future Pad (served, DualShock 4 protocol)")
    }

    func testARecordNeedingAFutureFamilyOrAFutureOpIsInert() async throws {
        let source = try await checked()
        let served = ServedDirectModels(index: source.index.state)
        for (productId, id) in [(UInt16(0x0F01), "future-pad-new-family"), (0x0F03, "future-pad-new-op")] {
            let held = try XCTUnwrap(record(source, 0x1209, productId))
            XCTAssertEqual(held.id, id)
            XCTAssertTrue(recordIsInert(held), id)
            XCTAssertNil(served.model(vendorId: 0x1209, productId: productId), id)
        }
    }

    func testTheMappingObjectRowIsLeftOutAndTheBuildsOwnRowStaysInForce() async throws {
        let source = try await checked()
        XCTAssertNil(record(source, 0x2DC8, 0x5006), "a mapping this reader cannot hold drops the row alone")
        XCTAssertNotNil(directModel(vendorId: 0x2DC8, productId: 0x5006), "the build's own table still names the pad")
    }

    func testTheMisauthoredRowIsLeftOutAndItsIssueNeverShows() async throws {
        let source = try await checked()
        XCTAssertNil(record(source, 0x1209, 0x0F04))
        XCTAssertNil(ServedDirectModels(index: source.index.state).model(vendorId: 0x1209, productId: 0x0F04))
    }

    func testTheSteamControllerOverBluetoothIsAsInVersion1() async throws {
        let source = try await checked()
        let served = try XCTUnwrap(source.index.state.record(vendorId: 0x28DE, productId: 0x1106, transport: .bluetooth))
        let bundled = try XCTUnwrap(BundledControllerDb.load()).database.records.first { $0.id == served.id }
        XCTAssertEqual(served, bundled)
    }
}

/// The future-reader set as committed under `Fixtures/future-reader`.
private struct FutureReaderFixture {
    static let paths = [ControllerDbFiles.controllers] + ["en", "bs", "de", "es", "fr", "pt-BR", "it"].map(ControllerDbFiles.strings)

    let manifest: Data
    let files: [String: Data]

    init(folder: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/future-reader")) throws
    {
        manifest = try Data(contentsOf: folder.appendingPathComponent(ControllerDbFiles.manifest))
        var files: [String: Data] = [:]
        for path in Self.paths {
            files[path] = try Data(contentsOf: folder.appendingPathComponent(path))
        }
        self.files = files
    }
}
