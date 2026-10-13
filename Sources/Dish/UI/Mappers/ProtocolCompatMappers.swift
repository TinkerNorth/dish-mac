// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import SwiftUI

/// The protocol chip a satellite row wears. Nothing for a satellite that is
/// current or not yet negotiated with; the soft hint for one that still
/// works at an older version; the hard word when one end must update
/// before a session can open.
func protocolCompatText(_ compat: ProtocolCompat, words: L10n = .app) -> String? {
    switch compat {
    case .unknown, .current: nil
    case .satelliteUpdateAvailable: words.satelliteUpdateRecommended
    case .satelliteUpdateRequired: words.satelliteUpdateRequiredChip
    case .dishUpdateRequired: words.dishUpdateRequiredChip
    }
}

/// Amber for the hint, red when a session cannot open, muted otherwise.
func protocolCompatColor(_ compat: ProtocolCompat) -> Color {
    switch compat {
    case .unknown, .current: DishTheme.muted
    case .satelliteUpdateAvailable: DishTheme.warning
    case .satelliteUpdateRequired, .dishUpdateRequired: DishTheme.error
    }
}
