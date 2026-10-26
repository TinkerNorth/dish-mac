// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// A section's eyebrow with its Scan button, and the bar under it while a
/// sweep runs. Discovery is a bounded sweep with nothing to stop, so the
/// button reports it and the bar is the busy cue. A page may add one more
/// button beside Scan.
struct ScanHeader: View {

    /// A button the header draws before Scan.
    struct Extra {
        let title: String
        let action: () -> Void
    }

    let title: String
    let scanTitle: String
    let scanEnabled: Bool
    let scanning: Bool
    let scan: () -> Void
    var extra: Extra?

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack(spacing: DishSpace.s4) {
                SectionHeader(title: title)
                Spacer()
                if let extra {
                    Button(extra.title, action: extra.action)
                        .buttonStyle(DishOutlinedButtonStyle())
                }
                Button(scanTitle, action: scan)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!scanEnabled)
            }
            if scanning {
                DishBar()
            }
        }
    }
}
