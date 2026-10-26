// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// What the crash report page shows and where its button goes.
struct CrashReportPageState: Equatable {
    let report: String
    /// The prefilled issue; nil when the report cannot ride in an address.
    let issueURL: URL?
}

func crashReportPageState(
    facts: ShellFacts,
    home: String = NSHomeDirectory(),
    system: String = ProcessInfo.processInfo.operatingSystemVersionString
) -> CrashReportPageState {
    let report = crashReportText(facts.crashLogText, appVersion: facts.update.currentVersion, home: home, system: system)
    return CrashReportPageState(report: report, issueURL: crashIssueURL(report))
}

/// The report as the user sees it and as the issue is prefilled: the log as
/// last read, redacted with this user's home, under the running build and system.
func crashReportText(_ rawLog: String, appVersion: String, home: String, system: String) -> String {
    CrashReport.build(rawLog: rawLog, home: home, appVersion: appVersion, system: system)
}

/// The prefilled issue, bounded to what a browser carries.
func crashIssueURL(_ report: String) -> URL? {
    CrashReport.issueURL(for: report)
}
