// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The three appearances the picker offers. `system` follows the OS; the
/// other two pin it. The storage tokens are the fleet's.
package enum ThemeMode: String, CaseIterable, Equatable {
    case system
    case light
    case dark

    /// Lenient: nil, empty, unknown or forward-newer reads as the default.
    package static func fromStorage(_ value: String?) -> ThemeMode {
        value.flatMap(ThemeMode.init(rawValue:)) ?? .system
    }
}
