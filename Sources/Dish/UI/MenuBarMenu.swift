// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The menu behind the menu-bar item: the dashboard headline, the way back
/// to the window, and the only Quit while the window is closed.
struct MenuBarMenu: View {

    @EnvironmentObject var model: AppModel
    let showWindow: () -> Void
    let showDiagnostics: () -> Void

    private let words = L10n.app

    var body: some View {
        Text(dashboardStatusText(model.connections))
        Divider()
        Button(words.showDish, action: showWindow)
        Button(words.diagnostics, action: showDiagnostics)
        Divider()
        Button(words.quit) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
