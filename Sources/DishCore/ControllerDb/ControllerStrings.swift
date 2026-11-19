// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The database's words: one flat table per locale (`strings/<locale>.json`),
// `en` complete and every other locale free to leave a key out, which then
// reads in English. Proper nouns, the controllers' names, live in `en` alone.

import Foundation

public struct ControllerStrings: Equatable, Sendable {
    public static let fallbackLocale = "en"
    /// The locales the fleet ships, in the manifest's order.
    public static let locales = ["en", "bs", "de", "es", "fr", "pt-BR"]

    /// Locale to key to text.
    public let tables: [String: [String: String]]

    public init(tables: [String: [String: String]]) {
        self.tables = tables
    }

    /// The text for `key` in `locale`: the locale's own table, else the
    /// table of its language ("de-AT" reads "de", "pt" reads "pt-BR"), else `en`.
    public func text(_ key: String, locale: String) -> String? {
        let own = table(for: locale)?[key]
        return own ?? tables[Self.fallbackLocale]?[key]
    }

    public func controllerName(_ id: String, locale: String) -> String? {
        text("controller.\(id).name", locale: locale)
    }

    public func issueTitle(_ id: String, locale: String) -> String? {
        text("issue.\(id).title", locale: locale)
    }

    public func issueBody(_ id: String, locale: String) -> String? {
        text("issue.\(id).body", locale: locale)
    }

    private func table(for locale: String) -> [String: String]? {
        if let exact = tables[locale] { return exact }
        let language = languageOf(locale)
        let sameLanguage = tables.keys.sorted().first { languageOf($0) == language }
        return sameLanguage.flatMap { tables[$0] }
    }
}

/// "pt-BR" and "pt_BR" are "pt".
private func languageOf(_ locale: String) -> String {
    let separators = CharacterSet(charactersIn: "-_")
    return locale.components(separatedBy: separators).first?.lowercased() ?? locale.lowercased()
}

/// One strings file: a flat object of string to string. A value that is not
/// a string is left out; anything but an object is refused.
public func decodeControllerStrings(_ data: Data) -> Result<[String: String], ControllerDbError> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.badJson) }
    return .success(object.compactMapValues { $0 as? String })
}
