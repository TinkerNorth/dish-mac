// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest

/// Every release carries the frame path's measurements: the workflow builds
/// the bench plain and with lock statistics, runs the lock laws, reports the
/// lock gate without enforcing it until the hot path is lock-free, and
/// release.yml runs it before publish, which ships its two files.
final class MeasurementsWorkflowTests: XCTestCase {

    private static let workflowPath = ".github/workflows/measurements.yml"
    private static let releasePath = ".github/workflows/release.yml"

    func testTheWorkflowMeasuresBothBuildsOnTheCIRunner() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        XCTAssertTrue(workflow.contains("runs-on: macos-26"), "the runner the rest of CI uses")
        let build = "swift build --configuration release --product DishBench"
        XCTAssertTrue(workflow.contains(build + "\n"), "the plain bench")
        XCTAssertTrue(workflow.contains(build + " -Xswiftc -DLOCK_STATS"), "the counting bench")
        XCTAssertTrue(workflow.contains("swift test --skip-build --filter LockLawTests"), "the lock laws run beside the bench")
        XCTAssertTrue(workflow.contains("--only S5 --mic-hz 1000"), "the microphone variant")
        XCTAssertTrue(workflow.contains("gh release download --pattern 'measurements-*.json'"), "the trend's baseline")
    }

    func testTheLockGateIsReportedAndNotYetEnforced() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        XCTAssertTrue(workflow.contains("bench/DishBench-plain report"))
        XCTAssertFalse(workflow.contains("--enforce-lock-gate"), "the optimisation PR enforces it once no gated role takes a lock")
    }

    func testPublishWaitsForTheMeasurementsAndShipsThem() throws {
        let release = try RepoFiles.read(Self.releasePath)
        XCTAssertTrue(release.contains("uses: ./.github/workflows/measurements.yml"))
        XCTAssertTrue(release.contains("needs: [required-secrets, harden, provenance, measurements]"))
        XCTAssertTrue(release.contains("name: measurements\n          path: release"), "the two files land beside the app")
    }
}
