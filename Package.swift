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
        // pinned by ImportBoundariesTests.
        .target(
            name: "DishCore",
            path: "Sources/DishCore",
            swiftSettings: warningsAreErrors
        ),
        // The unidirectional-dataflow kernel: StateSource, Composer, Controller,
        // Repository, AsyncState. Foundation + Combine only.
        .target(
            name: "DishKernel",
            path: "Sources/DishKernel",
            swiftSettings: warningsAreErrors
        ),
        // The headless engine: sockets, REST, stores, the controller bridge,
        // the composition root. No SwiftUI or AppKit; the app hands it
        // `LifecycleSignals` and binds to what it publishes.
        .target(
            name: "DishEngine",
            dependencies: ["DishCore", "DishKernel"],
            path: "Sources/DishEngine",
            swiftSettings: warningsAreErrors
        ),
        // The SwiftUI projection and the AppKit glue.
        .executableTarget(
            name: "Dish",
            dependencies: ["DishEngine", "DishCore", "DishKernel"],
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
            name: "DishEngineTests",
            dependencies: ["DishEngine", "DishKernelProbes", "LegacyFileKeychain"],
            path: "Tests/DishEngineTests",
            swiftSettings: warningsAreErrors
        ),
        .testTarget(
            name: "DishTests",
            dependencies: ["Dish", "DishEngine"],
            path: "Tests/DishTests",
            swiftSettings: warningsAreErrors
        ),
        // The rules of the repository, read from the tree: import boundaries,
        // the dependency graph, license headers, the version mirrors, the lint
        // thresholds, and the absence of suppressions and mutable statics.
        .testTarget(
            name: "ArchitectureTests",
            path: "Tests/ArchitectureTests",
            swiftSettings: warningsAreErrors
        ),
        .testTarget(
            name: "DishCoreTests",
            dependencies: ["DishCore"],
            path: "Tests/DishCoreTests",
            swiftSettings: warningsAreErrors
        ),
        // Emission probes and the repository contract every kernel user's
        // tests share. No XCTest dependency, so a regular target can hold it.
        .target(
            name: "DishKernelProbes",
            dependencies: ["DishKernel"],
            path: "Tests/Support/DishKernelProbes",
            swiftSettings: warningsAreErrors
        ),
        .testTarget(
            name: "DishKernelTests",
            dependencies: ["DishKernel", "DishKernelProbes"],
            path: "Tests/DishKernelTests",
            swiftSettings: warningsAreErrors
        )
    ],
    swiftLanguageModes: [.v5]
)
