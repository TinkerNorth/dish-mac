// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Destination: the paired hosts to pick, the satellites a sweep heard with
/// their Pair… and inline pairing card, as Connections draws them, the
/// Local Network prompt explained before the first scan, and the way to
/// Satellite when nothing answered.
struct SetupDestinationStepView: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    let step: SetupDestinationStep

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            SetupHeadingView(heading: step.heading)
            if let priming = step.priming {
                PrimingCard(state: priming, prime: model.primeLocalNetwork)
            }
            ScanHeader(
                title: step.foundTitle,
                scanTitle: step.scan.title,
                scanEnabled: step.scan.enabled,
                scanning: step.scan.showsBar,
                scan: model.startScan
            )
            ForEach(step.satellites) { row in
                DestinationRow(state: row, pick: model.pickSetupDestination)
            }
            ForEach(step.found) { row in
                FoundRow(state: row)
            }
            if !step.moonlight.isEmpty {
                SectionHeader(title: step.moonlightTitle)
                ForEach(step.moonlight) { row in
                    DestinationRow(state: row, pick: model.pickSetupDestination)
                }
            }
            if let empty = step.empty {
                NothingFoundCard(state: empty, secondary: model.startScan)
            }
            HStack(spacing: DishSpace.s4) {
                Text(step.footnote)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                Button(step.getApp.title, action: getApp)
                    .buttonStyle(.link)
                    .font(DishFont.caption)
            }
        }
    }

    private func getApp() {
        if let url = step.getApp.url { openURL(url) }
    }
}
