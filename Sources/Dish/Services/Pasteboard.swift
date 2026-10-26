// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import SwiftUI

/// The clipboard as a value the scene hands its pages, so a Copy button
/// calls an action instead of reaching for `NSPasteboard` itself. Outside
/// the scene (a test, a preview) it copies nothing.
struct Pasteboard {
    let copy: @Sendable (String) -> Void

    static let system = Pasteboard { copyToGeneralPasteboard($0) }
    static let inert = Pasteboard { ignoreCopy($0) }
}

private func copyToGeneralPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

private func ignoreCopy(_: String) {}

private struct PasteboardKey: EnvironmentKey {
    static let defaultValue = Pasteboard.inert
}

extension EnvironmentValues {
    var pasteboard: Pasteboard {
        get { self[PasteboardKey.self] }
        set { self[PasteboardKey.self] = newValue }
    }
}
