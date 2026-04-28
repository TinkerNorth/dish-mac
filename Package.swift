// swift-tools-version:5.9
// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import PackageDescription

let package = Package(
    name: "Dish",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dish",
            path: "Sources/Dish"
        ),
        .testTarget(
            name: "DishTests",
            dependencies: ["Dish"],
            path: "Tests/DishTests"
        )
    ]
)
