// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// The sentence shown for a connection failure. The engine vends the case;
/// this is the one place it is worded. A detail the satellite sent is shown
/// as it came.
func failureText(_ failure: ConnectionFailure, words: L10n = .app) -> String {
    switch failure {
    case .identityChanged: words.identityChanged
    case .protocolMismatch: words.protocolMismatch
    case .dishUpdateRequired: words.dishUpdateRequired
    case .satelliteUpdateRequired: words.satelliteUpdateRequired
    case .approvalDeclined: words.approvalDeclined
    case .approvalTimedOut: words.approvalTimedOut
    case .repairNeeded: words.repairNeeded
    case let .unreachable(detail): words.unreachable(detail)
    case .noSharedKey: words.noSharedKey
    case let .sessionRefused(detail): words.errorDetail(detail ?? words.connectionFailed)
    case .badSessionMaterial: words.badSessionMaterial
    case .sessionLinkFailed: words.sessionLinkFailed
    case .controllerNotApplied: words.controllerNotApplied
    case .noServersFound: words.noServersFound
    case .localNetworkDenied: words.localNetworkDenied
    case let .pairingRejected(detail): detail ?? words.pairingFailed
    }
}
