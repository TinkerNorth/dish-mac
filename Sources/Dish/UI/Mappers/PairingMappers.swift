// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The satellite rotates four-digit PINs; the Pair button waits for one.
func isValidPin(_ pin: String) -> Bool {
    pin.count == 4 && pin.allSatisfy(isASCIIDigit)
}

/// The digits a user typed, at most four, so the field can never hold more.
func clippedPin(_ typed: String) -> String {
    String(typed.filter(isASCIIDigit).prefix(4))
}

private func isASCIIDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
}
