// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// The end-to-end lane runs the same script a developer runs, against a
/// satellite release pinned by tag, and the driver's environment contract is
/// the one the script sets.
final class E2EWorkflowTests: XCTestCase {

    private static let workflowPath = ".github/workflows/e2e.yml"
    private static let scriptPath = "scripts/e2e_local.sh"
    private static let driverPath = "Tests/DishEngineTests/IntegrationLiveSatelliteE2ETests.swift"
    private static let environmentKeys = [
        "DISH_E2E_LIVE",
        "DISH_E2E_HOST",
        "DISH_E2E_REST_PORT",
        "DISH_E2E_UDP_PORT",
        "DISH_E2E_ADMIN_PORT"
    ]

    func testTheLaneRunsTheScriptAgainstATaggedSatellite() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        XCTAssertTrue(workflow.contains("run: bash \(Self.scriptPath)"), "CI drives the script a developer runs")
        XCTAssertTrue(workflow.contains("repository: TinkerNorth/satellite"))
        let tag = try XCTUnwrap(Self.capture(#"SATELLITE_TAG: "([0-9]+\.[0-9]+\.[0-9]+)""#, in: workflow), "the satellite is a release tag")
        XCTAssertTrue(workflow.contains("ref: ${{ env.SATELLITE_TAG }}"), "the checkout reads the one pin (\(tag))")
        XCTAssertTrue(
            workflow.contains("SATELLITE_REPO: ${{ github.workspace }}/satellite"),
            "the script is told where the checkout landed"
        )
        XCTAssertTrue(workflow.contains("runs-on: macos-26"), "the lane the rest of CI runs on")
    }

    func testTheScriptAndTheDriverAgreeOnTheEnvironment() throws {
        let script = try RepoFiles.read(Self.scriptPath)
        let driver = try RepoFiles.read(Self.driverPath)
        for key in Self.environmentKeys {
            XCTAssertTrue(script.contains("\(key)="), "the script sets \(key)")
            XCTAssertTrue(driver.contains("env[\"\(key)\"]"), "the driver reads \(key)")
        }
        XCTAssertTrue(script.contains("swift test --filter IntegrationLiveSatelliteE2ETests"), "the script runs the driver alone")
        XCTAssertTrue(driver.contains("XCTSkipUnless"), "a plain `swift test` skips the driver")
    }

    /// The lane's satellite is hermetic: its isolated home seeds a config
    /// that turns the update check off before the satellite starts, so the
    /// lane never phones GitHub, and satellite 2.1.3's updater crash (31 s
    /// after launch, when that check runs) never reaches it.
    func testTheScriptSeedsTheSatellitesConfigWithTheUpdateCheckOff() throws {
        let script = try RepoFiles.read(Self.scriptPath)
        XCTAssertTrue(script.contains("Library/Application Support/satellite"), "the satellite's config home")
        let seed = try XCTUnwrap(script.range(of: #""autoCheck": false"#), "no update check from a test lane")
        let launch = try XCTUnwrap(script.range(of: #"HOME="${E2E_HOME}" "${SATELLITE_BIN}""#))
        XCTAssertTrue(seed.lowerBound < launch.lowerBound, "seeded before the satellite starts")
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
