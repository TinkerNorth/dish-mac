// swift-tools-version:6.2
// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import PackageDescription

/// Every first-party target treats warnings as errors (CONTRIBUTING.md, "Zero
/// warnings"). The one exception, `LegacyFileKeychain`, is explained below.
let warningsAreErrors: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Dish",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        // The pure protocol core: wire codecs, crypto, protocol constants and
        // policy reducers. Foundation + CryptoKit only; the import allowlist is
        // pinned by CorePurityTests.
        .target(
            name: "DishCore",
            path: "Sources/DishCore",
            swiftSettings: warningsAreErrors
        ),
        .executableTarget(
            name: "Dish",
            dependencies: ["DishCore"],
            path: "Sources/Dish",
            resources: [
                // SwiftPM compiles the String Catalog into per-locale
                // Localizable.strings inside the bundle.
                .process("Resources")
            ],
            swiftSettings: warningsAreErrors
        ),
        // Test support only. Holds the one call to the deprecated SecKeychain
        // API (the only prompt-free way to mint a TLS identity for the in-process
        // satellite), compiled with warnings suppressed so that call cannot
        // spread: it is made nowhere else. See the file's header.
        .target(
            name: "LegacyFileKeychain",
            path: "Tests/Support/LegacyFileKeychain",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
        .testTarget(
            name: "DishTests",
            dependencies: ["Dish", "LegacyFileKeychain"],
            path: "Tests/DishTests",
            swiftSettings: warningsAreErrors
        ),
        .testTarget(
            name: "DishCoreTests",
            dependencies: ["DishCore"],
            path: "Tests/DishCoreTests",
            swiftSettings: warningsAreErrors
        )
    ],
    swiftLanguageModes: [.v5]
)
