// swift-tools-version:5.9
// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import PackageDescription

let package = Package(
    name: "Dish",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        // The suite's pure core: wire codecs, crypto, protocol constants and
        // policy reducers. Foundation + CryptoKit ONLY — no Network, AppKit,
        // GameController or app imports (PLAN D1). SwiftPM enforces the
        // dependency graph; the import allowlist itself is pinned by
        // CorePurityTests.
        .target(
            name: "DishCore",
            path: "Sources/DishCore"
        ),
        .executableTarget(
            name: "Dish",
            dependencies: ["DishCore"],
            path: "Sources/Dish",
            resources: [
                // The String Catalog lives at `Sources/Dish/Resources/Localizable.xcstrings`.
                // `.process` lets SwiftPM compile it into per-locale `.lproj/Localizable.strings`
                // inside the bundle so `String(localized:)` resolves at runtime.
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DishTests",
            dependencies: ["Dish"],
            path: "Tests/DishTests"
        ),
        .testTarget(
            name: "DishCoreTests",
            dependencies: ["DishCore"],
            path: "Tests/DishCoreTests"
        )
    ]
)
