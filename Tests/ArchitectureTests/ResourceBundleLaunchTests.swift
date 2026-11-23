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
    /// DishCore's own resolver, for the controller database it ships.
    private static let coreResolverPath = "Sources/DishCore/ControllerDb/BundledControllerDb.swift"
    private static let bundleScriptPath = "bundle.sh"
    private static let smokeScriptPath = "scripts/launch-smoke.sh"
    private static let smokeStep = "run: scripts/launch-smoke.sh Dish.app"
    private static let bundleStep = "run: ./bundle.sh release"
    fileprivate static let databaseCheckPath = "scripts/check-bundled-db.sh"
    private static let bundledDatabase = "Contents/Resources/Dish_DishCore.bundle/Contents/Resources/controllers-v1"
    /// The manifest and the seven data files it names.
    private static let publishedFiles = ["manifest.json", "controllers.json"] + ["en", "bs", "de", "es", "fr", "pt-BR"]
        .map { "strings/\($0).json" }

    func testOnlyTheResolverAsksSwiftPMForTheModuleBundle() throws {
        let offenders = try RepoFiles.swiftFiles(under: "Sources")
            .filter { $0 != Self.resolverPath && $0 != Self.coreResolverPath }
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

    func testTheCoreResolverLooksInTheAppsResourcesFirst() throws {
        let resolver = try RepoFiles.read(Self.coreResolverPath)
        XCTAssertTrue(resolver.contains("public static let name = \"Dish_DishCore.bundle\""))
        XCTAssertTrue(
            resolver.contains("inside(Bundle.main.resourceURL) ?? .module"),
            "the app's own resources first, SwiftPM's accessor last"
        )
    }

    func testTheBundleScriptShipsTheCoreBundleWhereItsResolverLooks() throws {
        let script = try RepoFiles.read(Self.bundleScriptPath)
        XCTAssertTrue(script.contains("cp -R \"$CORE_BUNDLE\" \"$APP/Contents/Resources/Dish_DishCore.bundle\""))
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
        XCTAssertTrue(script.contains("CFFIXED_USER_HOME="), "the app's support files, logs and caches land in a throwaway home")
        XCTAssertTrue(
            script.contains("/usr/libexec/PlistBuddy -c \"Set :CFBundleIdentifier $SMOKE_ID\" \"$SMOKE_APP/Contents/Info.plist\""),
            "macOS 27 writes preferences through the daemon whatever the environment says, so the launch is a copy under its own domain"
        )
        XCTAssertTrue(script.contains("SMOKE_ID=\"com.tinkernorth.dish.mac.launch-smoke\""))
        XCTAssertTrue(script.contains("defaults delete \"$SMOKE_ID\""), "and that domain is deleted however the launch ends")
        XCTAssertTrue(script.contains("SMOKE_EXECUTABLE=\"$SMOKE_APP/Contents/MacOS/Dish\""), "the copy is what runs")
        XCTAssertFalse(script.contains("\"$EXECUTABLE\" > \"$LAUNCH_LOG\""), "never the app under the owner's own domain")
        let attributes = try FileManager.default.attributesOfItem(atPath: RepoFiles.url(Self.smokeScriptPath).path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertNotEqual(permissions & 0o111, 0, "the workflows run the script directly")
    }

    // MARK: - The bundled controller database

    /// A build that ships a broken copy launches on the empty set, so the
    /// gate checks the built app's copy before it launches it.
    func testTheLaunchChecksTheBuiltAppsControllerDatabaseFirst() throws {
        let script = try RepoFiles.read(Self.smokeScriptPath)
        let check = try XCTUnwrap(script.range(of: "\(Self.databaseCheckPath) \"$APP/\(Self.bundledDatabase)\""))
        let launch = try XCTUnwrap(script.range(of: "\"$SMOKE_EXECUTABLE\" > \"$LAUNCH_LOG\""))
        XCTAssertTrue(check.lowerBound < launch.lowerBound, "checked before it launches")
    }

    func testTheDatabaseCheckPassesTheCopyAsPublished() throws {
        let copy = try DatabaseCopy()
        defer { copy.remove() }
        XCTAssertEqual(try copy.check(), 0)
    }

    func testTheDatabaseCheckFailsAFileWithOneByteMore() throws {
        let copy = try DatabaseCopy()
        defer { copy.remove() }
        let handle = try FileHandle(forWritingTo: copy.folder.appendingPathComponent("strings/de.json"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        XCTAssertNotEqual(try copy.check(), 0)
    }

    func testTheDatabaseCheckFailsAMissingFile() throws {
        for path in Self.publishedFiles {
            let copy = try DatabaseCopy()
            defer { copy.remove() }
            try FileManager.default.removeItem(at: copy.folder.appendingPathComponent(path))
            XCTAssertNotEqual(try copy.check(), 0, path)
        }
    }

    func testTheDatabaseCheckFailsAChangedByteOfTheSameSize() throws {
        let copy = try DatabaseCopy()
        defer { copy.remove() }
        let file = copy.folder.appendingPathComponent("controllers.json")
        var body = try Data(contentsOf: file)
        body[body.index(before: body.endIndex)] ^= 0x01
        try body.write(to: file)
        XCTAssertNotEqual(try copy.check(), 0)
    }

    /// macOS shows this the first time either use opens a pad's microphone:    /// macOS shows this the first time either use opens a pad's
    /// microphone:
    /// the mic switch's sending, or the inspector's test, which sends nothing.
    func testTheMicrophonePromptDescribesBothUsesOfTheMicrophone() throws {
        let script = try RepoFiles.read(Self.bundleScriptPath)
        let key = try XCTUnwrap(script.range(of: "<key>NSMicrophoneUsageDescription</key>"))
        let sentence = try XCTUnwrap(script[key.upperBound...].split(separator: "\n").first)
        XCTAssertTrue(sentence.contains("mic switch is on"), "the switch's use")
        XCTAssertTrue(sentence.contains("microphone test"), "the inspector's use")
        XCTAssertTrue(sentence.contains("sends nothing"), "and that the test sends nothing")
    }

    private static func namesTheModuleBundle(_ line: String) -> Bool {
        line.contains("Bundle.module") || line.contains("bundle: .module") || line.contains("?? .module")
    }
}

/// The bundled database copied to a scratch folder, and the gate's check
/// run over it.
private struct DatabaseCopy {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dish-db-check-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: RepoFiles.url("Sources/DishCore/Resources/controllers-v1"), to: folder)
    }

    func check() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [RepoFiles.url(ResourceBundleLaunchTests.databaseCheckPath).path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
