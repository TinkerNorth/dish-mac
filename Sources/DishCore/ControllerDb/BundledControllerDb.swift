// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The copy of the database the app was built with: dbVersion 1, the files
// under `Resources/controllers-v1`, byte for byte as dish-website publishes
// them. A client never edits its copy; a newer one comes from the website.

import Foundation

/// The bundle that carries DishCore's resources. Inside `Dish.app` it sits in
/// `Contents/Resources`, where `bundle.sh` copies it, and that is the first
/// place asked; SwiftPM's accessor is the fallback for `swift run` and the
/// tests, as `ResourceBundle` is for the app's own.
public enum CoreResourceBundle {
    public static let name = "Dish_DishCore.bundle"

    public static let core: Bundle = inside(Bundle.main.resourceURL) ?? .module

    static func inside(_ resources: URL?) -> Bundle? {
        let candidate = resources?.appendingPathComponent(name)
        return candidate.flatMap(Bundle.init(url:))
    }
}

public enum BundledControllerDb {
    public static let folder = "controllers-v1"

    /// Every file of the bundled version by its published path, the
    /// manifest among them.
    public static func files(in bundle: Bundle = CoreResourceBundle.core) -> [String: Data] {
        guard let root = bundle.resourceURL?.appendingPathComponent(folder) else { return [:] }
        let paths = [ControllerDbFiles.manifest, ControllerDbFiles.controllers] + ControllerStrings.locales.map(ControllerDbFiles.strings)
        var files: [String: Data] = [:]
        for path in paths {
            files[path] = try? Data(contentsOf: root.appendingPathComponent(path))
        }
        return files
    }

    /// The bundled set, verified against its own manifest; nil only for a
    /// build that shipped a broken copy, which the tests refuse.
    public static func load(in bundle: Bundle = CoreResourceBundle.core) -> ControllerDbSet? {
        let files = files(in: bundle)
        guard let body = files[ControllerDbFiles.manifest],
              case let .success(manifest) = decodeControllerDbManifest(body) else { return nil }
        return verifiedControllerDbSet(manifest: manifest, files: files)
    }

    /// What the index holds when the bundled copy is missing: nothing.
    public static let empty = ControllerDbSet(
        manifest: ControllerDbManifest(dbVersion: 0, files: [:]),
        database: ControllerDatabase(dbVersion: 0, records: []),
        strings: ControllerStrings(tables: [:])
    )
}
