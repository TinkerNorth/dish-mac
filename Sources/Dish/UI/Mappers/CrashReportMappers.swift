// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// The report as the user sees it and as the issue is prefilled: the log on
/// disk, redacted with this user's home, under the running build and system.
func crashReportText(
    _ log: CrashLog,
    appVersion: String,
    home: String = NSHomeDirectory(),
    system: String = ProcessInfo.processInfo.operatingSystemVersionString
) -> String {
    CrashReport.build(rawLog: log.read(), home: home, appVersion: appVersion, system: system)
}

/// The prefilled issue, bounded to what a browser carries.
func crashIssueURL(_ report: String) -> URL? {
    CrashReport.issueURL(for: report)
}
