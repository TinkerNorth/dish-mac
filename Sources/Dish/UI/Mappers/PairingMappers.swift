// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// The satellite rotates four-digit PINs, and the client PIN has the same shape.
private let pinDigits = 4
/// The rejection that earns the refresh hint: by then the likeliest cause is
/// a satellite screen that re-drew and minted a new code.
private let refreshHintRejections = 3

/// What the pairing card draws: the typed PIN's four cells and its error,
/// the operator request when one is filed, and the buttons.
struct PairingCardState: Equatable {
    let pinPrompt: String
    let pinFieldLabel: String
    let typedCells: [String]
    let cellStroke: Color
    let pinError: String?
    let fieldEnabled: Bool
    let request: PairingRequestState?
    let pairTitle: String
    let showsPairSpinner: Bool
    let pairEnabled: Bool
    let cancelTitle: String
}

/// The operator request's half of the card: the client PIN to type on the
/// satellite and where the request stands.
struct PairingRequestState: Equatable {
    let orWord: String
    let approvePrompt: String
    let clientPinCells: [String]
    let status: String
    let statusColor: Color
    let showsProgress: Bool
    let hint: String?
    let newCodeTitle: String?
}

/// The card for one attempt, with the digits typed so far.
func pairingCardState(_ attempt: PairingAttempt, satelliteName: String, typed: String, words: L10n = .app) -> PairingCardState {
    let handedOff = attempt.phase == .approved
    let typingOpen = !attempt.submittingPin && !handedOff
    let pinError = attempt.rejection.map { rejection in
        pinRejectionText(rejection, satelliteName: satelliteName, rejections: attempt.rejections, words: words)
    }
    return PairingCardState(
        pinPrompt: words.enterSatellitePin,
        pinFieldLabel: words.pairingPinField,
        typedCells: pinCells(typed),
        cellStroke: pinError == nil ? DishTheme.outline : DishTheme.error,
        pinError: pinError,
        fieldEnabled: typingOpen,
        request: pairingRequestState(attempt, satelliteName: satelliteName, words: words),
        pairTitle: attempt.submittingPin ? words.pairing : words.pair,
        showsPairSpinner: attempt.submittingPin,
        pairEnabled: typingOpen && isValidPin(clippedPin(typed)),
        cancelTitle: words.cancel
    )
}

/// The operator request's half, absent while none is filed.
func pairingRequestState(_ attempt: PairingAttempt, satelliteName: String, words: L10n = .app) -> PairingRequestState? {
    guard let line = requestStatusLine(attempt.phase, satelliteName: satelliteName, words: words) else { return nil }
    return PairingRequestState(
        orWord: words.orWord,
        approvePrompt: words.typePinOnSatellite(satelliteName),
        clientPinCells: pinCells(attempt.clientPin),
        status: line.text,
        statusColor: line.color,
        showsProgress: line.waiting,
        hint: line.waiting ? words.aboutTwoMinutes : nil,
        newCodeTitle: line.offersNewCode ? words.newCode : nil
    )
}

/// Why the typed PIN did not pair, with the refresh hint from the third
/// rejection on.
func pinRejectionText(_ rejection: PinRejection, satelliteName: String, rejections: Int, words: L10n = .app) -> String {
    let reason = switch rejection {
    case .wrongPin: words.pinNotAccepted(satelliteName)
    case .pending: words.notApprovedYet(satelliteName)
    case .versionMismatch: words.differentSatelliteVersion(satelliteName)
    case .unreachable: words.couldNotReach(satelliteName)
    case .identityChanged: words.identityChanged
    }
    let addsHint = rejections >= refreshHintRejections
    return addsHint ? reason + " " + words.codeChangesOnRefresh : reason
}

/// One status line of the operator request.
private struct RequestStatusLine {
    let text: String
    let color: Color
    let waiting: Bool
    let offersNewCode: Bool
}

/// Only a decline and an expiry offer a new code: a changed identity or
/// another protocol version ends the request in a way no new code rescues.
private func requestStatusLine(_ phase: ReversePairingPhase, satelliteName: String, words: L10n) -> RequestStatusLine? {
    switch phase {
    case .idle:
        nil
    case .awaiting:
        RequestStatusLine(text: words.waitingForApproval, color: DishTheme.muted, waiting: true, offersNewCode: false)
    case .approved:
        RequestStatusLine(text: words.approvedConnecting, color: DishTheme.success, waiting: false, offersNewCode: false)
    case .declined:
        RequestStatusLine(text: words.operatorDeclined, color: DishTheme.error, waiting: false, offersNewCode: true)
    case .timedOut:
        RequestStatusLine(text: words.noApprovalCodeExpired, color: DishTheme.muted, waiting: false, offersNewCode: true)
    case .identityChanged:
        RequestStatusLine(text: words.identityChanged, color: DishTheme.error, waiting: false, offersNewCode: false)
    case .versionMismatch:
        RequestStatusLine(
            text: words.differentSatelliteVersion(satelliteName),
            color: DishTheme.error,
            waiting: false,
            offersNewCode: false
        )
    }
}

/// Four cells, each one digit or empty.
private func pinCells(_ digits: String) -> [String] {
    let characters = Array(clippedPin(digits))
    return (0 ..< pinDigits).map { index in index < characters.count ? String(characters[index]) : "" }
}

/// The satellite rotates four-digit PINs; the Pair button waits for one.
func isValidPin(_ pin: String) -> Bool {
    pin.count == pinDigits && pin.allSatisfy(isASCIIDigit)
}

/// The digits a user typed, at most four, so the field can never hold more.
func clippedPin(_ typed: String) -> String {
    String(typed.filter(isASCIIDigit).prefix(pinDigits))
}

private func isASCIIDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
}
