// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One pad the host holds, and what has been sent on it.
package struct MoonlightPadFacts: Equatable {
    package let number: UInt8
    package let slotId: String
    /// The CONTROLLER_ARRIVAL type the pad was plugged in as.
    package let type: UInt8
    package let reports: Int

    package init(number: UInt8, slotId: String, type: UInt8, reports: Int) {
        self.number = number
        self.slotId = slotId
        self.type = type
        self.reports = reports
    }
}

/// A Moonlight host's session as the Diagnostics window reads it: the phase,
/// the app the session settled on, the control link's round trip, what the
/// host last said of itself, and each pad it holds. Every figure is one the
/// rest of the app already acts on.
package struct MoonlightHostDiagnostics: Equatable {
    package let phase: MoonlightSessionPhase
    package let appName: String?
    package let controlRoundTripMs: Int64?
    package let info: MoonlightServerInfo?
    package let pads: [MoonlightPadFacts]

    package init(
        phase: MoonlightSessionPhase,
        appName: String?,
        controlRoundTripMs: Int64?,
        info: MoonlightServerInfo?,
        pads: [MoonlightPadFacts]
    ) {
        self.phase = phase
        self.appName = appName
        self.controlRoundTripMs = controlRoundTripMs
        self.info = info
        self.pads = pads
    }

    /// A host nothing has opened this run: idle, with whatever its probe said.
    package static func resting(info: MoonlightServerInfo?) -> MoonlightHostDiagnostics {
        MoonlightHostDiagnostics(phase: .idle, appName: nil, controlRoundTripMs: nil, info: info, pads: [])
    }

    /// Read off the live connection, pads by number.
    @MainActor
    static func read(_ connection: MoonlightConnection, info: MoonlightServerInfo?) -> MoonlightHostDiagnostics {
        let pads = connection.pads.sorted { $0.number < $1.number }.map { pad in
            MoonlightPadFacts(
                number: pad.number,
                slotId: pad.slotId,
                type: pad.announced.type,
                reports: connection.link.reportsSent(for: pad.number)
            )
        }
        return MoonlightHostDiagnostics(
            phase: connection.phase,
            appName: connection.sessionAppName,
            controlRoundTripMs: connection.controlRoundTripMs,
            info: info,
            pads: pads
        )
    }
}
