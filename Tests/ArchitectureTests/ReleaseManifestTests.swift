// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest

/// The update check has one producer, `release.yml`, and one reader,
/// `UpdateManifest`; the strings they must agree on are pinned here, with
/// the floor's two rules: a strict triple, never above the release.
final class ReleaseManifestTests: XCTestCase {

    private static let policyPath = "packaging/update-policy.json"
    private static let workflowPath = ".github/workflows/release.yml"
    private static let readerPath = "Sources/DishCore/Update/UpdateManifest.swift"
    private static let permalink = "https://github.com/TinkerNorth/dish-mac/releases/latest/download/latest.json"

    // MARK: - The policy file

    func testTheFloorIsAStrictTriple() throws {
        XCTAssertNotNil(try Self.triple(minimumSupportedVersion()), "minimumSupportedVersion must be MAJOR.MINOR.PATCH")
    }

    func testTheFloorIsNeverAboveTheRelease() throws {
        let floor = try XCTUnwrap(try Self.triple(minimumSupportedVersion()))
        let release = try XCTUnwrap(Self.triple(RepoFiles.read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(
            floor == release || floor.lexicographicallyPrecedes(release),
            "a floor above VERSION would make UpdateManifest.parse reject the manifest for every client"
        )
    }

    // MARK: - The producer and the reader agree

    func testTheWorkflowEmitsWhatTheReaderAccepts() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        for required in [
            "\"schema\": 1,",
            "\"product\": \"dish-mac\",",
            "\"channel\": \"stable\",",
            "\"minimumSupportedVersion\": minimum,",
            "\"releaseNotesUrl\": f\"https://github.com/{repo}/releases/tag/{tag}\",",
            "packaging/update-policy.json"
        ] {
            XCTAssertTrue(workflow.contains(required), "release.yml must carry \(required)")
        }
    }

    // MARK: - The signing gate is advisory until the Developer ID exists

    func testTheSigningGateIsAdvisoryAndTheStableNameNeverCarriesASuffix() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        let gateIsAVariable = workflow.contains("ENFORCE: ${{ vars.ENFORCE_RELEASE_SIGNING }}")
        let laterJobsLearnTheOutcome = workflow.contains("signed: ${{ steps.check.outputs.signed }}")
        let stableNameKept = workflow.contains("\"dist/dish-mac.zip\"")
        let stableNameSuffixed = workflow.contains("dish-mac${suffix}.zip")
        let gatesGrantWhatIsAsked = workflow.contains("pull-requests: read\n      security-events: write")
        let dispatchNamesTheTag = workflow.contains("tag=\"${{ inputs.tag || github.ref_name }}\"")
        let generatorBuiltFromThePin = workflow.contains("compile-generator: true")
        XCTAssertTrue(gateIsAVariable, "the hard gate is a repository variable")
        XCTAssertTrue(laterJobsLearnTheOutcome, "later jobs learn whether the app is signed")
        XCTAssertTrue(stableNameKept, "the stable asset keeps its name, signed or not")
        XCTAssertFalse(stableNameSuffixed, "the stable asset never carries the -unsigned suffix")
        XCTAssertTrue(gatesGrantWhatIsAsked, "the gates job grants what the shared workflow asks for")
        XCTAssertTrue(dispatchNamesTheTag, "a dispatch run names the zip after the tag, not the branch")
        XCTAssertTrue(generatorBuiltFromThePin, "a commit-pinned SLSA generator is built from its source")
    }

    func testTheWorkflowReadsTheFloorFromThePolicyFile() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        XCTAssertTrue(workflow.contains("json.load(open(\"\(Self.policyPath)\"))[\"minimumSupportedVersion\"]"))
    }

    func testTheManifestShipsBesideTheAppInTheHardenedBundle() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        XCTAssertTrue(workflow.contains("name: macos-manifest"), "the manifest job uploads its own artifact")
        XCTAssertTrue(workflow.contains("pattern: macos*"), "harden merges the app and the manifest")
        XCTAssertTrue(workflow.contains("merge-multiple: true"))
        XCTAssertTrue(workflow.contains("needs: [release, manifest]"), "harden waits for both")
    }

    func testTheReaderFetchesThisRepositorysPermalink() throws {
        let reader = try RepoFiles.read(Self.readerPath)
        XCTAssertTrue(reader.contains("\"\(Self.permalink)\""), "UpdateManifest must fetch the Latest permalink of this repository")
        XCTAssertTrue(reader.contains("public static let product = \"dish-mac\""))
        XCTAssertTrue(reader.contains("public static let channel = \"stable\""))
    }

    func testTheManifestAssetNameIsThePermalinkLeaf() throws {
        let workflow = try RepoFiles.read(Self.workflowPath)
        let leaf = try XCTUnwrap(URL(string: Self.permalink)?.lastPathComponent)
        XCTAssertEqual(leaf, "latest.json")
        XCTAssertTrue(workflow.contains("dist/\(leaf)"), "the job writes the asset under the name the permalink resolves")
    }

    // MARK: - Helpers

    private func minimumSupportedVersion() throws -> String {
        let json = try RepoFiles.read(Self.policyPath)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(root["minimumSupportedVersion"] as? String, "the policy names a floor")
    }

    /// The three numbers of a strict MAJOR.MINOR.PATCH, else nil.
    private static func triple(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(strictNumber)
        return numbers.count == 3 ? numbers : nil
    }

    /// Digits only, no leading zero unless the number is zero.
    private static func strictNumber(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
        guard part.count == 1 || part.first != "0" else { return nil }
        return Int(part)
    }
}
