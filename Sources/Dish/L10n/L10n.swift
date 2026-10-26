// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Every word the app shows, by screen. Views read `L10n.app`; a test builds
/// one over a single language's tables. A key is its English text, written
/// as a C format string, so `LocalizationTests` can match it against the
/// catalog verbatim.
struct L10n {
    let catalog: StringCatalog

    static let app = L10n(catalog: StringCatalog(bundle: .module))

    /// The product name, never translated.
    let appName = "Dish"
}

extension L10n {

    // MARK: - Dashboard

    var noConnectionsYet: String {
        catalog.text("No connections yet")
    }

    var settings: String {
        catalog.text("Settings")
    }

    var noControllersConnected: String {
        catalog.text("No controllers connected")
    }

    func paired(_ count: Int) -> String {
        catalog.format("%lld paired", count)
    }

    func activeConnections(_ count: Int) -> String {
        catalog.format("%lld active connections", count)
    }

    func onlineOfTotal(_ live: Int, _ total: Int) -> String {
        catalog.format("%lld of %lld online", live, total)
    }
}

extension L10n {

    // MARK: - Toasts and loaders

    var dismiss: String {
        catalog.text("Dismiss")
    }

    var loading: String {
        catalog.text("Loading")
    }

    var working: String {
        catalog.text("Working")
    }
}
