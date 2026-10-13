// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The crash log on disk: where it lives, whether an earlier run left one,
/// its text, and its removal once the user has dealt with it. The handler
/// appends to it; nothing else writes it and nothing transmits it.
package struct CrashLog: Equatable {

    package let url: URL

    package init(url: URL) {
        self.url = url
    }

    /// `~/Library/Logs/Dish/crash.log`, beside the system's own logs.
    package static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CrashLog {
        CrashLog(url: home.appendingPathComponent("Library/Logs/Dish/crash.log", isDirectory: false))
    }

    package var path: String {
        url.path
    }

    /// A log exists when the file is there and not empty.
    package var exists: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    /// The log's text, or nothing when there is none.
    package func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Removes the log. "Already gone" is the requested end state, not a
    /// failure.
    @discardableResult
    package func discard() -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
