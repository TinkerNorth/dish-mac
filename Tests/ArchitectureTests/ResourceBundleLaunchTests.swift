// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// Releases 1.0.2 to 1.2.0 crashed at launch on every Mac but the one that
/// built them: SwiftPM's native resource accessor looked in the app's root
/// and in the CI runner's build directory, while `bundle.sh` puts the
/// resource bundle in `Contents/Resources`. These pin the three facts that
/// keep a shipped app launching: the app asks for its bundle in one place,
/// the bundle script ships it where that place looks, and CI launches the
/// bundled app with no build tree beside it.
final class ResourceBundleLaunchTests: XCTestCase {

    private static let resolverPath = "Sources/Dish/L10n/ResourceBundle.swift"
    private static let bundleScriptPath = "bundle.sh"
    private static let smokeScriptPath = "scripts/launch-smoke.sh"
    private static let smokeStep = "run: scripts/launch-smoke.sh Dish.app"
    private static let bundleStep = "run: ./bundle.sh release"

    func testOnlyTheResolverAsksSwiftPMForTheModuleBundle() throws {
        let offenders = try RepoFiles.swiftFiles(under: "Sources")
            .filter { $0 != Self.resolverPath }
            .flatMap { path in try RepoFiles.offendingLines(in: path, where: Self.namesTheModuleBundle) }
        XCTAssertEqual(offenders, [], "read the app's resources through ResourceBundle.dish, never Bundle.module")
    }

    func testTheResolverLooksInTheAppsResourcesFirst() throws {
        let resolver = try RepoFiles.read(Self.resolverPath)
        XCTAssertTrue(resolver.contains("static let name = \"Dish_Dish.bundle\""))
        XCTAssertTrue(
            resolver.contains("inside(Bundle.main.resourceURL) ?? .module"),
            "the app's own resources first, SwiftPM's accessor last"
        )
    }

    func testTheBundleScriptShipsTheBundleWhereTheResolverLooks() throws {
        let script = try RepoFiles.read(Self.bundleScriptPath)
        XCTAssertTrue(script.contains("cp -R \"$RESOURCE_BUNDLE\" \"$APP/Contents/Resources/Dish_Dish.bundle\""))
    }

    func testEveryWorkflowThatBundlesTheAppLaunchesIt() throws {
        for workflowPath in [".github/workflows/macos-ci.yml", ".github/workflows/release.yml"] {
            let workflow = try RepoFiles.read(workflowPath)
            let bundle = try XCTUnwrap(workflow.range(of: Self.bundleStep), "\(workflowPath) bundles the app")
            let launch = try XCTUnwrap(workflow.range(of: Self.smokeStep), "\(workflowPath) launches the bundled app")
            XCTAssertTrue(bundle.lowerBound < launch.lowerBound, "\(workflowPath) launches what it bundled")
        }
    }

    func testTheLocalGatesLaunchTheBundledAppToo() throws {
        let gates = try RepoFiles.read("scripts/ci-local.sh")
        XCTAssertTrue(gates.contains("\(Self.smokeScriptPath) Dish.app"), "a green local run is a green CI run")
    }

    func testTheLaunchHidesTheBuildTreeAndIsolatesThePreferences() throws {
        let script = try RepoFiles.read(Self.smokeScriptPath)
        XCTAssertTrue(script.contains("mv .build \"$HIDDEN_BUILD\""), "the native accessor's fallback is the build tree")
        XCTAssertTrue(script.contains("trap restore_build EXIT"), "the build tree comes back however the launch ends")
        XCTAssertTrue(script.contains("CFFIXED_USER_HOME="), "a launch never touches the developer's own preferences")
        let attributes = try FileManager.default.attributesOfItem(atPath: RepoFiles.url(Self.smokeScriptPath).path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertNotEqual(permissions & 0o111, 0, "the workflows run the script directly")
    }

    private static func namesTheModuleBundle(_ line: String) -> Bool {
        line.contains("Bundle.module") || line.contains("bundle: .module")
    }
}
