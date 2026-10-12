// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// The sentence shown for a connection failure. The engine vends the case;
/// this is the one place it is worded.
func failureText(_ failure: ConnectionFailure) -> String {
    switch failure {
    case .identityChanged:
        "This satellite's security identity changed. If it was reinstalled, forget it here and pair again."
    case .protocolMismatch:
        "This app and the satellite speak different protocol versions. Update both to the latest version."
    case .approvalDeclined:
        "The satellite declined the pairing request."
    case .approvalTimedOut:
        "No response from the satellite. The pairing request timed out."
    case .repairNeeded:
        "This satellite no longer recognizes this device. Re-pair needed."
    case let .unreachable(detail):
        "Server unreachable — has it moved networks? (\(detail))"
    case .noSharedKey:
        "No shared key — re-pair needed"
    case let .sessionRefused(detail):
        "Error: \(detail ?? "connection failed")"
    case .badSessionMaterial:
        "Bad token from server"
    case .sessionLinkFailed:
        "The satellite accepted, but the controller link would not open. Try again."
    case .controllerNotApplied:
        "Server could not apply the controller"
    case .noServersFound:
        "No servers found — check your network"
    case let .pairingRejected(detail):
        detail ?? "Pairing failed"
    }
}
