// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - The Share crash reports switch

    var shareCrashReports: String {
        catalog.text("Share crash reports")
    }

    var shareCrashReportsDetail: String {
        catalog.text(
            "Share anonymized crash logs and stack traces with TinkerNorth to help fix bugs. No gameplay or controller input is included."
        )
    }

    var crashUploadImpossible: String {
        catalog.text("This build carries no crash-reporting address, so nothing is sent whatever the switch says.")
    }
}
