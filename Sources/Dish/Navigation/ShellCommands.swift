// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The keyboard's way around the shell: ⌘, for Settings, ⌘1 to ⌘3 for the
/// rail's top destinations, ⌘[ back, enabled exactly while there is a page
/// to go back from.
struct ShellCommands: Commands {

    @ObservedObject var navigation: NavigationStore
    let show: (ExternalRequest) -> Void

    private let words = L10n.app

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(words.settings) { show(.showDestination(.settings)) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(before: .sidebar) {
            Button(words.home) { show(.showDestination(.home)) }
                .keyboardShortcut("1", modifiers: .command)
            Button(words.controllers) { show(.showDestination(.controllers)) }
                .keyboardShortcut("2", modifiers: .command)
            Button(words.connections) { show(.showDestination(.connections)) }
                .keyboardShortcut("3", modifiers: .command)
            Button(words.back) { navigation.send(.pop) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(navigation.state.path.isEmpty)
            Divider()
        }
    }
}
