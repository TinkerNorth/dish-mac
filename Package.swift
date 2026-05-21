// swift-tools-version:5.9
// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import PackageDescription

let package = Package(
    name: "Dish",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dish",
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
        )
    ]
)
