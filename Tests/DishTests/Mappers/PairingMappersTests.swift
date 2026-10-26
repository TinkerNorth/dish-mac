// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI
import XCTest
@testable import Dish

/// The pairing card's words, colours and switches for every phase of the
/// operator request and every answer to the typed PIN.
final class PairingMappersTests: XCTestCase {

    private static let name = "Desk PC"

    private func card(
        _ phase: ReversePairingPhase = .awaiting,
        clientPin: String = "4081",
        typed: String = "",
        submitting: Bool = false,
        rejection: PinRejection? = nil,
        rejections: Int = 0
    ) -> PairingCardState {
        let attempt = PairingAttempt(
            clientPin: clientPin,
            phase: phase,
            submittingPin: submitting,
            rejection: rejection,
            rejections: rejections
        )
        return pairingCardState(attempt, satelliteName: Self.name, typed: typed)
    }

    private func request(_ phase: ReversePairingPhase) throws -> PairingRequestState {
        try XCTUnwrap(card(phase).request, "\(phase) shows the operator request")
    }

    // MARK: - The typed PIN

    func testTheCardAsksForTheSatellitesFourDigitPin() {
        let state = card()
        XCTAssertEqual(state.pinPrompt, "Enter the 4-digit PIN shown on the Satellite’s screen.")
        XCTAssertEqual(state.pinFieldLabel, "Pairing PIN, 4 digits")
        XCTAssertEqual(state.cancelTitle, "Cancel")
    }

    func testTheTypedDigitsFillTheFourCellsInOrder() {
        XCTAssertEqual(card(typed: "").typedCells, ["", "", "", ""])
        XCTAssertEqual(card(typed: "40").typedCells, ["4", "0", "", ""])
        XCTAssertEqual(card(typed: "4081").typedCells, ["4", "0", "8", "1"])
        XCTAssertEqual(card(typed: "40 81 9").typedCells, ["4", "0", "8", "1"], "a paste keeps four digits")
    }

    func testPairWaitsForFourDigits() {
        XCTAssertFalse(card(typed: "408").pairEnabled)
        XCTAssertTrue(card(typed: "4081").pairEnabled)
        XCTAssertEqual(card(typed: "4081").pairTitle, "Pair")
        XCTAssertFalse(card(typed: "4081").showsPairSpinner)
        XCTAssertTrue(card(typed: "4081").fieldEnabled)
    }

    func testASubmissionInFlightLocksTheFieldAndSaysPairing() {
        let state = card(typed: "4081", submitting: true)
        XCTAssertEqual(state.pairTitle, "Pairing…")
        XCTAssertTrue(state.showsPairSpinner)
        XCTAssertFalse(state.pairEnabled)
        XCTAssertFalse(state.fieldEnabled)
    }

    func testAnApprovalLocksTheTypedPin() {
        let state = card(.approved, typed: "4081")
        XCTAssertFalse(state.pairEnabled, "the session is already opening")
        XCTAssertFalse(state.fieldEnabled)
    }

    func testNoRejectionMeansNoErrorAndPlainCells() {
        XCTAssertNil(card().pinError)
        XCTAssertEqual(card().cellStroke, DishTheme.outline)
    }

    func testEveryRejectionHasItsSentenceAndRedCells() {
        let expected: [PinRejection: String] = [
            .wrongPin: "That PIN wasn’t accepted. Check the code on Desk PC and try again.",
            .pending: "Desk PC hasn’t approved the pairing yet.",
            .versionMismatch: "Desk PC is running a different Satellite version. Update both, then pair again.",
            .unreachable: "Couldn’t reach Desk PC. Make sure it’s on and on your network.",
            .identityChanged: "This satellite's security identity changed. If it was reinstalled, forget it here and pair again."
        ]
        for (rejection, sentence) in expected {
            let state = card(rejection: rejection, rejections: 1)
            XCTAssertEqual(state.pinError, sentence, "\(rejection)")
            XCTAssertEqual(state.cellStroke, DishTheme.error, "\(rejection)")
        }
    }

    func testTheThirdRejectionAddsTheRefreshHint() {
        let second = card(rejection: .wrongPin, rejections: 2)
        XCTAssertEqual(second.pinError, "That PIN wasn’t accepted. Check the code on Desk PC and try again.")
        let third = card(rejection: .wrongPin, rejections: 3)
        XCTAssertEqual(
            third.pinError,
            "That PIN wasn’t accepted. Check the code on Desk PC and try again. The code changes if the Satellite screen was refreshed."
        )
    }

    // MARK: - The operator request

    func testNoRequestFiledShowsOnlyTheTypedPin() {
        XCTAssertNil(card(.idle).request)
    }

    func testARequestShowsTheClientPinToTypeOnTheSatellite() throws {
        let filed = try request(.awaiting)
        XCTAssertEqual(filed.orWord, "or")
        XCTAssertEqual(filed.approvePrompt, "Type this PIN on Desk PC to approve the pairing.")
        XCTAssertEqual(filed.clientPinCells, ["4", "0", "8", "1"])
    }

    func testAwaitingShowsTheBarTheWaitAndTheHint() throws {
        let awaiting = try request(.awaiting)
        XCTAssertEqual(awaiting.status, "Waiting for approval on the satellite…")
        XCTAssertEqual(awaiting.statusColor, DishTheme.muted)
        XCTAssertTrue(awaiting.showsProgress)
        XCTAssertEqual(awaiting.hint, "~2 min")
        XCTAssertNil(awaiting.newCodeTitle)
    }

    func testAnApprovalSaysSoInTheSuccessColour() throws {
        let approved = try request(.approved)
        XCTAssertEqual(approved.status, "Approved — connecting…")
        XCTAssertEqual(approved.statusColor, DishTheme.success)
        XCTAssertFalse(approved.showsProgress)
        XCTAssertNil(approved.hint)
        XCTAssertNil(approved.newCodeTitle)
    }

    func testADeclineIsAnErrorAndOffersANewCode() throws {
        let declined = try request(.declined)
        XCTAssertEqual(declined.status, "The operator declined the pairing.")
        XCTAssertEqual(declined.statusColor, DishTheme.error)
        XCTAssertEqual(declined.newCodeTitle, "New code")
        XCTAssertFalse(declined.showsProgress)
        XCTAssertNil(declined.hint)
    }

    func testAnExpiryOffersANewCodeWithoutAlarm() throws {
        let expired = try request(.timedOut)
        XCTAssertEqual(expired.status, "No approval — the code expired.")
        XCTAssertEqual(expired.statusColor, DishTheme.muted)
        XCTAssertEqual(expired.newCodeTitle, "New code")
        XCTAssertFalse(expired.showsProgress)
    }

    func testAChangedIdentityIsAnErrorNoNewCodeCanFix() throws {
        let changed = try request(.identityChanged)
        XCTAssertEqual(
            changed.status,
            "This satellite's security identity changed. If it was reinstalled, forget it here and pair again."
        )
        XCTAssertEqual(changed.statusColor, DishTheme.error)
        XCTAssertNil(changed.newCodeTitle)
    }

    func testAVersionMismatchNamesTheSatelliteAndOffersNoNewCode() throws {
        let mismatch = try request(.versionMismatch)
        XCTAssertEqual(mismatch.status, "Desk PC is running a different Satellite version. Update both, then pair again.")
        XCTAssertEqual(mismatch.statusColor, DishTheme.error)
        XCTAssertNil(mismatch.newCodeTitle)
    }
}
