// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest

/// The layering, as the compiler cannot state it: which frameworks each
/// module may import. SwiftPM enforces the module dependency graph; this
/// pins the system frameworks, so the pure core stays pure, the engine stays
/// free of UI, and the UI stays free of IO.
final class ImportBoundariesTests: XCTestCase {

    private struct Layer {
        let directory: String
        let allowed: Set<String>
    }

    private static let layers: [Layer] = [
        // CommonCrypto is Apple's C crypto, pure computation: the AES-ECB
        // block primitive the Moonlight pairing prescribes and CryptoKit lacks.
        Layer(directory: "Sources/DishCore", allowed: ["Foundation", "CryptoKit", "CommonCrypto"]),
        Layer(directory: "Sources/DishKernel", allowed: ["Foundation", "Combine"]),
        Layer(
            directory: "Sources/DishEngine",
            allowed: [
                "Foundation", "Combine", "CryptoKit", "Darwin", "Network", "dnssd", "SystemConfiguration", "GameController",
                "CoreHaptics", "IOKit", "Security", "os", "AudioToolbox", "CoreAudio", "AVFoundation", "DishCore", "DishKernel"
            ]
        ),
        Layer(directory: "Sources/DishCrashUpload", allowed: ["Foundation", "Sentry", "DishCore", "DishEngine"]),
        Layer(
            directory: "Sources/Dish",
            allowed: [
                "Foundation", "Combine", "SwiftUI", "AppKit", "UserNotifications", "DishCore", "DishEngine", "DishKernel", "DishCrashUpload"
            ]
        ),
        Layer(directory: "Tests/Support/DishKernelProbes", allowed: ["Foundation", "Combine", "DishKernel"]),
        Layer(directory: "Tests/Support/LegacyFileKeychain", allowed: ["Foundation", "Security"])
    ]

    func testEveryLayerHasSources() {
        for layer in Self.layers {
            XCTAssertFalse(RepoFiles.swiftFiles(under: layer.directory).isEmpty, "no sources under \(layer.directory)")
        }
    }

    func testEachLayerImportsOnlyItsAllowedModules() throws {
        for layer in Self.layers {
            for file in RepoFiles.swiftFiles(under: layer.directory) {
                let imports = try RepoFiles.imports(of: RepoFiles.read(file))
                let forbidden = imports.filter { !layer.allowed.contains($0) }
                XCTAssertEqual(forbidden, [], "\(file) imports \(forbidden); \(layer.directory) allows \(layer.allowed.sorted())")
            }
        }
    }

    func testTheEngineNeverImportsAUIFramework() throws {
        for file in RepoFiles.swiftFiles(under: "Sources/DishEngine") {
            let imports = try RepoFiles.imports(of: RepoFiles.read(file))
            XCTAssertFalse(imports.contains("SwiftUI") || imports.contains("AppKit"), "\(file) reaches a UI framework")
        }
    }

    func testTheUILayerDoesNoIO() throws {
        let ioModules: Set = ["Network", "Darwin", "GameController", "Security", "CryptoKit", "IOKit", "CoreHaptics"]
        for file in RepoFiles.swiftFiles(under: "Sources/Dish") {
            let imports = try Set(RepoFiles.imports(of: RepoFiles.read(file)))
            XCTAssertTrue(imports.isDisjoint(with: ioModules), "\(file) imports an IO framework: \(imports.intersection(ioModules))")
        }
    }
}
