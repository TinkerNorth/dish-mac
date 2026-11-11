// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The bundle that carries the app's compiled String Catalog. Inside
/// `Dish.app` it sits in `Contents/Resources`, where `bundle.sh` copies it,
/// and that is the first place asked. SwiftPM's `Bundle.module` is only the
/// fallback, for `swift run` and the tests, whose bundle sits beside the
/// binary: the accessor SwiftPM's native build system generates looks in the
/// app's root and then in the compiling machine's build directory, and traps
/// when neither exists, which is every Mac but the one that built the app.
enum ResourceBundle {
    static let name = "Dish_Dish.bundle"

    static let dish: Bundle = inside(Bundle.main.resourceURL) ?? .module

    /// The bundle called `name` in `resources`, when one is there.
    static func inside(_ resources: URL?) -> Bundle? {
        let candidate = resources?.appendingPathComponent(name)
        return candidate.flatMap(Bundle.init(url:))
    }
}
