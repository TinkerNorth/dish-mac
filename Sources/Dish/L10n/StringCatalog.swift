// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The one reader of the compiled String Catalog. `bundle` holds the tables;
/// `locale` picks the plural rules and the number formatting, and defaults
/// to the language the bundle chose for this user.
struct StringCatalog {
    let bundle: Bundle
    let locale: Locale

    init(bundle: Bundle, locale: Locale) {
        self.bundle = bundle
        self.locale = locale
    }

    init(bundle: Bundle) {
        self.init(bundle: bundle, locale: Locale(identifier: bundle.preferredLocalizations.first ?? "en"))
    }

    /// The translation of `key`, or the key itself (the English) when the
    /// tables lack it.
    func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The translation of a format key with its arguments filled in. A
    /// plural variation is chosen by `locale`, not by the system locale.
    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
