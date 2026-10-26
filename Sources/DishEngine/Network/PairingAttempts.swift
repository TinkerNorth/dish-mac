// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import Foundation

/// Why a typed satellite PIN did not pair, for the card's inline error.
package enum PinRejection: Equatable {
    /// The satellite refused the PIN.
    case wrongPin
    /// The satellite answered that it is still waiting for its operator.
    case pending
    /// No protocol version both ends speak.
    case versionMismatch
    /// No answer at all.
    case unreachable
    /// The satellite's TLS certificate no longer matches its pin.
    case identityChanged
}

/// One satellite's pairing as the card shows it: both paths at once, the
/// operator request (its client PIN and phase) beside the typed PIN (in
/// flight, and why the last one was refused, and how many were).
package struct PairingAttempt: Equatable {
    package var clientPin: String
    package var phase: ReversePairingPhase
    package var submittingPin: Bool
    package var rejection: PinRejection?
    package var rejections: Int

    package init(
        clientPin: String = "",
        phase: ReversePairingPhase = .idle,
        submittingPin: Bool = false,
        rejection: PinRejection? = nil,
        rejections: Int = 0
    ) {
        self.clientPin = clientPin
        self.phase = phase
        self.submittingPin = submittingPin
        self.rejection = rejection
        self.rejections = rejections
    }
}

/// The pairing attempts by satellite id. An attempt lives from its first
/// request until a session takes over or the user cancels; a declined or
/// expired request stays, so the card can say so and offer a new code.
@MainActor
package final class PairingAttempts: StateSource<[String: PairingAttempt]> {

    init() {
        super.init(initial: [:])
    }

    /// A fresh operator request: its client PIN, awaiting the answer. The
    /// typed PIN's history stays with the attempt.
    func awaitApproval(_ id: String, clientPin: String) {
        var attempt = state[id] ?? PairingAttempt()
        attempt.clientPin = clientPin
        attempt.phase = .awaiting
        put(attempt, for: id)
    }

    /// The operator request's last word, for an attempt still on the card.
    func finish(_ id: String, phase: ReversePairingPhase) {
        guard var attempt = state[id] else { return }
        attempt.phase = phase
        put(attempt, for: id)
    }

    /// A typed PIN is on its way; the last error goes with the new try.
    func startSubmission(_ id: String) {
        var attempt = state[id] ?? PairingAttempt()
        attempt.submittingPin = true
        attempt.rejection = nil
        put(attempt, for: id)
    }

    func reject(_ id: String, _ rejection: PinRejection) {
        guard var attempt = state[id] else { return }
        attempt.submittingPin = false
        attempt.rejection = rejection
        attempt.rejections += 1
        put(attempt, for: id)
    }

    func end(_ id: String) {
        updateState { current in
            var next = current
            next.removeValue(forKey: id)
            return next
        }
    }

    private func put(_ attempt: PairingAttempt, for id: String) {
        updateState { current in
            var next = current
            next[id] = attempt
            return next
        }
    }
}
