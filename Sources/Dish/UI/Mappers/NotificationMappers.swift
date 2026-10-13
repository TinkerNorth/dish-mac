// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import SwiftUI

/// A toast's rail and glyph colour, by severity.
func severityColor(_ severity: DishNotification.Severity) -> Color {
    switch severity {
    case .info: DishTheme.primary
    case .success: DishTheme.success
    case .warn: DishTheme.warning
    case .error: DishTheme.error
    }
}
