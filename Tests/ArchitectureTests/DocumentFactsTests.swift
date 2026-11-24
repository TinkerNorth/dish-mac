// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Facts a document repeats from code, tied to the code: the crash reporter's
// version, the protocol number, the pinned tools, the Xcode the workflows
// select, the components SBOM against THIRD_PARTY.md, and the README's
// version, links and the family's shared text. A bump that moves one copy
// fails here, and the message names the file to edit.

import XCTest

final class DocumentFactsTests: XCTestCase {

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: sentry-cocoa

    func testThirdPartyNamesTheSentryVersionPackageResolvedPins() throws {
        let resolved = try RepoFiles.read("Package.resolved")
        let pinned = try XCTUnwrap(
            firstMatch(#""identity"\s*:\s*"sentry-cocoa"[^}]*?"version"\s*:\s*"([0-9.]+)""#, in: resolved),
            "Package.resolved has no sentry-cocoa pin"
        )
        let notice = try RepoFiles.read("THIRD_PARTY.md")
        let named = allMatches(#"sentry-cocoa(?:\]\([^)]*\))?(?: \|)? ([0-9]+\.[0-9]+\.[0-9]+)"#, in: notice)
        XCTAssertEqual(named.count, 2, "THIRD_PARTY.md names sentry-cocoa's version in the summary table and in section 2a")
        for version in named {
            let edit = "edit the version in THIRD_PARTY.md (summary row and section 2a), "
                + "then copy the file to Sources/Dish/Resources/THIRD_PARTY.md"
            XCTAssertEqual(version, pinned, "Package.resolved pins sentry-cocoa \(pinned): \(edit)")
        }
    }

    func testPackageSwiftPinsTheVersionPackageResolvedDoes() throws {
        let resolved = try RepoFiles.read("Package.resolved")
        let pinned = firstMatch(#""identity"\s*:\s*"sentry-cocoa"[^}]*?"version"\s*:\s*"([0-9.]+)""#, in: resolved)
        let manifest = try RepoFiles.read("Package.swift")
        XCTAssertEqual(
            firstMatch(#"sentry-cocoa[^)]*exact:\s*"([0-9.]+)""#, in: manifest),
            pinned,
            "Package.swift and Package.resolved must pin the same sentry-cocoa"
        )
    }

    func testThirdPartyDoesNotClaimTheAppHasNoPackageDependencies() throws {
        let notice = try RepoFiles.read("THIRD_PARTY.md").replacingOccurrences(of: "\n", with: " ")
        XCTAssertFalse(
            notice.contains("declares no package dependencies"),
            "Package.swift depends on sentry-cocoa; THIRD_PARTY.md must not say otherwise"
        )
    }

    // MARK: protocol

    func testTheDocumentsNameTheProtocolTheCodeOffers() throws {
        let constants = try RepoFiles.read("Sources/DishCore/ProtocolConstants.swift")
        let offered = try XCTUnwrap(
            firstMatch(#"static let protocolVersion\s*=\s*([0-9]+)"#, in: constants),
            "ProtocolConstants.protocolVersion not found"
        )
        let security = try RepoFiles.read("SECURITY.md")
        let named = allMatches(#"\(protocol ([0-9]+)"#, in: security)
        XCTAssertFalse(named.isEmpty, "SECURITY.md names the wire protocol in its scope list")
        for number in named {
            XCTAssertEqual(number, offered, "the client offers protocol \(offered) (ProtocolConstants.protocolVersion): edit SECURITY.md")
        }
        for path in ["README.md", "docs/contract.md"] {
            let text = try RepoFiles.read(path)
            let bold = allMatches(#"offers \*\*protocol ([0-9]+)\*\*"#, in: text)
            for number in bold {
                XCTAssertEqual(number, offered, "the client offers protocol \(offered): edit \(path)")
            }
        }
    }

    // MARK: tools

    private func toolsScript() throws -> String {
        try RepoFiles.read("scripts/tools.sh")
    }

    func testTheDocumentsNameTheToolVersionsToolsShPins() throws {
        let tools = try toolsScript()
        let format = try XCTUnwrap(firstMatch(#"SWIFTFORMAT_VERSION="([0-9.]+)""#, in: tools))
        let lint = try XCTUnwrap(firstMatch(#"SWIFTLINT_VERSION="([0-9.]+)""#, in: tools))
        let notice = try RepoFiles.read("THIRD_PARTY.md")
        let copies = "edit THIRD_PARTY.md and its copy under Sources/Dish/Resources"
        let namedFormat = firstMatch(#"\[SwiftFormat\]\([^)]*\) \| ([0-9.]+)"#, in: notice)
        XCTAssertEqual(namedFormat, format, "scripts/tools.sh pins SwiftFormat \(format): \(copies)")
        let namedLint = firstMatch(#"\[SwiftLint\]\([^)]*\) \| ([0-9.]+)"#, in: notice)
        XCTAssertEqual(namedLint, lint, "scripts/tools.sh pins SwiftLint \(lint): \(copies)")
        let contributing = try RepoFiles.read("CONTRIBUTING.md").replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(contributing.contains("SwiftFormat \(format)"), "edit CONTRIBUTING.md: SwiftFormat \(format)")
        XCTAssertTrue(contributing.contains("SwiftLint \(lint)"), "edit CONTRIBUTING.md: SwiftLint \(lint)")
    }

    func testNoWorkflowOrScriptRepeatsAToolPin() throws {
        let tools = try toolsScript()
        for digestName in ["SWIFTFORMAT_SHA256", "SWIFTLINT_SHA256"] {
            let digest = try XCTUnwrap(firstMatch("\(digestName)=\"([0-9a-f]{64})\"", in: tools))
            XCTAssertEqual(digest.count, 64)
            for path in ["scripts/ci-local.sh", "scripts/check-format.sh", ".github/workflows/macos-ci.yml"] {
                let text = try RepoFiles.read(path)
                XCTAssertFalse(text.contains(digest), "\(path) repeats a pin: it belongs in scripts/tools.sh alone")
                XCTAssertFalse(text.contains("SWIFTFORMAT_VERSION=") || text.contains("SWIFTLINT_VERSION="), "\(path) repeats a pin")
            }
        }
    }

    // MARK: shared security and release tools

    private func envValue(_ name: String, in text: String) -> String? {
        firstMatch("\(name): \"([0-9.]+)\"", in: text)
    }

    func testToolsShPinsTheScannersTheSharedSecurityWorkflowPins() throws {
        let tools = try toolsScript()
        let security = try RepoFiles.read(".github/workflows/_security.yml")
        let pairs = [
            ("OSV_SCANNER_VERSION", "OSV-Scanner"),
            ("GITLEAKS_VERSION", "gitleaks"),
            ("PYYAML_VERSION", "PyYAML")
        ]
        for (name, label) in pairs {
            let local = firstMatch("\(name)=\"([0-9.]+)\"", in: tools)
            let shared = envValue(name, in: security)
            XCTAssertNotNil(local, "scripts/tools.sh pins \(label)")
            XCTAssertEqual(local, shared, "scripts/tools.sh and _security.yml pin one \(label)")
        }
    }

    func testThirdPartyNamesTheScannersAndReleaseToolsTheWorkflowsPin() throws {
        let notice = try RepoFiles.read("THIRD_PARTY.md")
        let security = try RepoFiles.read(".github/workflows/_security.yml")
        let harden = try RepoFiles.read(".github/workflows/_release_harden.yml")
        let pins: [(name: String, version: String?)] = [
            ("OSV-Scanner", envValue("OSV_SCANNER_VERSION", in: security)),
            ("gitleaks", envValue("GITLEAKS_VERSION", in: security)),
            ("cosign", envValue("COSIGN_VERSION", in: harden)),
            ("Syft", envValue("SYFT_VERSION", in: harden)),
            ("Grype", envValue("GRYPE_VERSION", in: harden))
        ]
        for pin in pins {
            let named = firstMatch("\\[\(pin.name)\\]\\([^)]*\\) \\| ([0-9.]+)", in: notice)
            XCTAssertNotNil(pin.version, "\(pin.name) is pinned in a shared workflow")
            XCTAssertEqual(
                named,
                pin.version,
                "a shared workflow pins \(pin.name) \(pin.version ?? "?"): edit THIRD_PARTY.md and its bundled copy"
            )
        }
    }

    func testTheSharedWorkflowsAreCalledNotCopied() throws {
        let release = try RepoFiles.read(".github/workflows/release.yml")
        let security = try RepoFiles.read(".github/workflows/security.yml")
        let ci = try RepoFiles.read(".github/workflows/macos-ci.yml")
        XCTAssertTrue(security.contains("uses: ./.github/workflows/_security.yml"))
        XCTAssertTrue(release.contains("uses: ./.github/workflows/_security.yml"), "the tag re-runs the gates")
        XCTAssertTrue(release.contains("uses: ./.github/workflows/_release_harden.yml"), "the tag hardens through the shared workflow")
        XCTAssertTrue(ci.contains("uses: ./.github/workflows/_release_harden.yml"), "pull requests dry-run the same workflow")
        XCTAssertTrue(ci.contains("dry-run: true"))
        for text in [release, security, ci] {
            XCTAssertFalse(text.contains("cosign sign-blob"), "signing is the shared workflow's, not inline")
            XCTAssertFalse(text.contains("TODO_REPLACE_WITH_UPSTREAM_SHA256"), "no unpinned-tool branch")
        }
    }

    // MARK: components SBOM

    private func writtenComponents() throws -> [[String: Any]] {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("dish-mac-components-\(UUID().uuidString).spdx.json")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [RepoFiles.url("scripts/write-sbom.sh").path, out.path, "0.0.0-test"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "scripts/write-sbom.sh failed")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        return try XCTUnwrap(document["packages"] as? [[String: Any]])
    }

    func testTheComponentsSbomNamesEveryComponentThirdPartySaysReachesTheUser() throws {
        let packages = try writtenComponents()
        func versions(of name: String) -> [String] {
            packages.filter { ($0["name"] as? String)?.lowercased() == name.lowercased() }
                .compactMap { $0["versionInfo"] as? String }
        }
        let notice = try RepoFiles.read("THIRD_PARTY.md")
        var shipped = 0
        for line in notice.split(separator: "\n") where line.hasPrefix("| [") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 4, !cells[4].contains("Not in the app") else { continue }
            let name = try XCTUnwrap(firstMatch(#"^\[([^\]]+)\]"#, in: cells[1]))
            shipped += 1
            let named = versions(of: name)
            XCTAssertFalse(named.isEmpty, "THIRD_PARTY.md says \(name) reaches the user: scripts/write-sbom.sh must name it")
            if let commit = firstMatch(#"commit `([0-9a-f]{7,40})`"#, in: cells[1]) {
                XCTAssertTrue(
                    named.contains { $0.hasPrefix(commit) },
                    "\(name) is at commit \(commit) (THIRD_PARTY.md), the SBOM says \(named)"
                )
            } else {
                XCTAssertTrue(named.contains(cells[2]), "\(name) is \(cells[2]) in THIRD_PARTY.md, the SBOM says \(named)")
            }
        }
        XCTAssertGreaterThanOrEqual(shipped, 2, "THIRD_PARTY.md's summary names sentry-cocoa and ENet as reaching the user")
        let manifestData = try Data(contentsOf: RepoFiles.url("Sources/DishCore/Resources/controllers-v1/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let dbVersion = try XCTUnwrap(manifest["dbVersion"] as? Int)
        XCTAssertEqual(versions(of: "dish-controller-database"), ["\(dbVersion)"], "the SBOM names the bundled controller database")
    }

    func testTheReleaseZipIsStagedWithItsComponentsSbom() throws {
        let stage = try RepoFiles.read("scripts/stage-zip.sh")
        XCTAssertTrue(
            stage.contains("scripts/write-sbom.sh \"dist/dish-mac-components.spdx.json\""),
            "stage-zip.sh writes the components SBOM into dist/, so the dry run and the tag both carry it"
        )
    }

    // MARK: README

    func testEveryRelativeLinkInTheReadmePointsAtAFileThatExists() throws {
        let readme = try RepoFiles.read("README.md")
        let targets = allMatches(#"\]\(([^)\s]+)\)"#, in: readme)
        XCTAssertFalse(targets.isEmpty, "README.md links nothing")
        for target in targets where !target.contains("://") && !target.hasPrefix("mailto:") && !target.hasPrefix("#") {
            let path = String(target.split(separator: "#", maxSplits: 1)[0])
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: RepoFiles.url(path).path),
                "README.md links \(target), which is not in the repository"
            )
        }
    }

    func testTheReadmeNamesTheVersionInVersionFile() throws {
        let version = try RepoFiles.read("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        let readme = try RepoFiles.read("README.md")
        let named = try XCTUnwrap(
            firstMatch(#"Dish for macOS ([0-9]+\.[0-9]+\.[0-9]+) is the current release\."#, in: readme),
            "README.md must say \"Dish for macOS X.Y.Z is the current release.\""
        )
        XCTAssertEqual(named, version, "VERSION is \(version): edit README.md's Download line")
        let mentioned = Set(allMatches(#"dish-([0-9]+\.[0-9]+\.[0-9]+)-unsigned\.zip"#, in: readme))
        XCTAssertTrue(mentioned.isSubset(of: [version]), "README.md names a versioned zip other than \(version)")
    }

    func testTheReadmeCarriesTheFamilysSharedTextWordForWord() throws {
        let fixture = try RepoFiles.read("Tests/ArchitectureTests/Fixtures/readme-shared.md")
        let body = try XCTUnwrap(fixture.range(of: "-->\n")).upperBound
        let blocks = fixture[body...]
            .components(separatedBy: "\n%%%\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(blocks.count, 6, "the fixture holds the six SHARED blocks this README carries")
        let readme = try RepoFiles.read("README.md")
        for block in blocks {
            XCTAssertTrue(
                readme.contains(block),
                "README.md must carry the family's SHARED text verbatim (see Fixtures/readme-shared.md): \(block.prefix(80))…"
            )
        }
    }

    // MARK: Xcode

    func testEveryWorkflowSelectsTheSameXcodeByVersion() throws {
        let directory = RepoFiles.url(".github/workflows")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".yml") }
        var selected = Set<String>()
        for name in names {
            let text = try RepoFiles.read(".github/workflows/\(name)")
            for line in text.split(separator: "\n") where line.contains("xcode-select") {
                let version = firstMatch(#"/Applications/Xcode_([0-9.]+)\.app"#, in: String(line))
                XCTAssertNotNil(version, "\(name) must select Xcode by version, not /Applications/Xcode.app: \(line)")
                version.map { _ = selected.insert($0) }
            }
        }
        XCTAssertEqual(selected.count, 1, "every workflow selects the same Xcode (got \(selected.sorted()))")
        let contributing = try RepoFiles.read("CONTRIBUTING.md").replacingOccurrences(of: "\n", with: " ")
        if let version = selected.first {
            XCTAssertTrue(contributing.contains("Xcode \(version)"), "edit CONTRIBUTING.md: the workflows select Xcode \(version)")
        }
    }
}
