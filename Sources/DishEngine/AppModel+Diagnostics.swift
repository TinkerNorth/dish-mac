// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// A page whose being on screen starts or stops work in the engine.
package enum ObservedPage: Equatable {
    /// The Diagnostics source ticks while its page shows.
    case diagnostics
    /// The inspector is armed on one controller while its page shows.
    case inspector(slotId: String)
    /// Settings shows the crash-report row while a log waits.
    case settings
    /// Connections scans as it opens; leaving it closes its pairing card.
    case connections
    /// Moonlight hosts scans as it opens; leaving it ends the pairing its PIN card waits on.
    case moonlightHosts
    /// Home and Controllers tick the live rates while they show.
    case home
    case controllers
    /// Configure binding opens a draft of the pad's binding; leaving drops it.
    case configureBinding(slotId: String)
}

/// The pages' lifecycle as intents: a view's `onAppear` and `onDisappear`
/// forward here and do nothing else.
package extension AppModel {

    func pageAppeared(_ page: ObservedPage) {
        switch page {
        case .diagnostics: diagnostics.start()
        case let .inspector(slotId): inspect(slotId: slotId)
        case .settings: refreshCrashLogPresence()
        case .connections: scanAsThePageOpens()
        case .moonlightHosts: scanMoonlightHosts()
        case .home, .controllers: telemetry.show()
        case let .configureBinding(slotId): openBindingDraft(slotId: slotId)
        }
    }

    /// Leaving the inspector disarms it and stops the mic meter it started.
    func pageDisappeared(_ page: ObservedPage) {
        switch page {
        case .diagnostics: diagnostics.stop()
        case let .inspector(slotId): leaveInspector(slotId: slotId)
        case .settings: break
        case .connections: leftConnections()
        case .moonlightHosts: leftMoonlightHosts()
        case .home, .controllers: telemetry.hide()
        case .configureBinding: closeBindingDraft()
        }
    }

    func discardCrashLog() {
        crashLog.discard()
        refreshCrashLogPresence()
    }

    private func leaveInspector(slotId: String) {
        stopInspecting()
        stopMicMeter(slotId: slotId)
    }
}
