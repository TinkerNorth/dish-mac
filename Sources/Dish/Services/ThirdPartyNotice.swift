// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The bundled copy of `THIRD_PARTY.md`, nil when the build left it out.
func thirdPartyNotice(in bundle: Bundle) -> String? {
    guard let url = bundle.url(forResource: "THIRD_PARTY", withExtension: "md") else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
}
