// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

private let readConditions = BundleDeviceConditions(
    battery: nil,
    thermal: .serious,
    powerSave: true,
    wifi: BundleWifi(band: "5", rssiDbm: -60, linkSpeedMbps: 400)
)

@Sendable
private func readTheMac() -> BundleDeviceConditions {
    readConditions
}

/// The report as the pages reach it: opening the page prepares it, the
/// file carries the person's words and the Mac's conditions, Save
/// diagnostics carries neither, and both files are written under the
/// contract's name.
@MainActor
final class AppModelSupportReportTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        model = AppModel(
            store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()),
            defaults: defaults,
            appVersion: "1.4.0",
            hidCensus: FakeHidCensus(),
            discovery: WifiConnectionManager.DiscoveryPaths { WifiConnectionManager.ScanResult(broadcast: [], mdns: []) },
            machine: HostMachine(model: "Mac14,2", osMajor: 26, osMinor: 1, arch: "arm64"),
            deviceConditions: DeviceConditionsReading(read: readTheMac)
        )
    }

    override func tearDown() {
        model.pageDisappeared(.supportReport)
        model = nil
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func prepared() async {
        model.pageAppeared(.supportReport)
        await model.reportPreparation.settled()
    }

    func testOpeningTheReportPreparesIt() async {
        XCTAssertEqual(model.shellFacts.reportPreparation.phase, .idle)
        model.pageAppeared(.supportReport)
        XCTAssertTrue(model.shellFacts.reportPreparation.isLoading)
        await model.reportPreparation.settled()
        XCTAssertEqual(model.shellFacts.reportPreparation.data?.conditions, readConditions)
    }

    func testTheReportCarriesTheWordsAndTheMacsConditions() async throws {
        await prepared()
        let draft = SupportReportDraft(category: .connection, text: "Stutters every few seconds.", slotId: nil)
        let file = try object(model.supportReportData(draft, atMs: 1))
        let report = try XCTUnwrap(file["report"] as? [String: Any])
        XCTAssertEqual(report["category"] as? String, "connection")
        XCTAssertEqual(report["text"] as? String, "Stutters every few seconds.")
        let device = try XCTUnwrap(file["device"] as? [String: Any])
        XCTAssertEqual(device["thermal"] as? String, "serious")
        XCTAssertEqual(device["powerSave"] as? Bool, true)
    }

    func testThePreviewIsTheFileItWillWrite() async throws {
        await prepared()
        let draft = SupportReportDraft(category: .question, text: "Hi", slotId: nil)
        let preview = try object(Data(model.supportReportPreview(draft).utf8))
        XCTAssertEqual((preview["report"] as? [String: Any])?["text"] as? String, "Hi")
    }

    func testTheReportsFileIsWrittenUnderTheContractsName() async throws {
        await prepared()
        let url = try XCTUnwrap(model.writeSupportReport(SupportReportDraft(category: .other, text: "x", slotId: nil)))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("dish-diagnostics-dish-mac-"))
        XCTAssertNotNil(try object(Data(contentsOf: url))["report"])
    }

    func testSaveDiagnosticsCarriesNoReportAndNoConditions() async throws {
        await prepared()
        let url = try XCTUnwrap(model.writeDiagnosticsBundle())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = try object(Data(contentsOf: url))
        XCTAssertNil(file["report"])
        XCTAssertNil((file["device"] as? [String: Any])?["thermal"])
    }
}
