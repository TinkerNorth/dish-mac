// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

/// The small mappers: the light-bar picker, the toast colours, the PIN
/// field, and every connection failure's sentence.
final class WordMappersTests: XCTestCase {

    func testEveryLightbarModeHasItsWord() {
        XCTAssertEqual(lightbarModeText(.followGame), "Follow game")
        XCTAssertEqual(lightbarModeText(.off), "Off")
    }

    func testEverySeverityHasItsColour() {
        XCTAssertEqual(severityColor(.info), DishTheme.primary)
        XCTAssertEqual(severityColor(.success), DishTheme.success)
        XCTAssertEqual(severityColor(.warn), DishTheme.warning)
        XCTAssertEqual(severityColor(.error), DishTheme.error)
    }

    func testAPinIsExactlyFourASCIIDigits() {
        XCTAssertTrue(isValidPin("1234"))
        XCTAssertFalse(isValidPin("123"))
        XCTAssertFalse(isValidPin("12345"))
        XCTAssertFalse(isValidPin("12a4"))
        XCTAssertFalse(isValidPin("１２３４"))
    }

    func testTypingKeepsOnlyTheFirstFourDigits() {
        XCTAssertEqual(clippedPin("12a345"), "1234")
        XCTAssertEqual(clippedPin("1 2"), "12")
        XCTAssertEqual(clippedPin(""), "")
    }

    func testEveryFailureHasItsSentence() {
        XCTAssertEqual(
            failureText(.identityChanged),
            "This satellite's security identity changed. If it was reinstalled, forget it here and pair again."
        )
        XCTAssertEqual(
            failureText(.protocolMismatch),
            "This app and the satellite speak different protocol versions. Update both to the latest version."
        )
        XCTAssertEqual(failureText(.approvalDeclined), "The satellite declined the pairing request.")
        XCTAssertEqual(failureText(.approvalTimedOut), "No response from the satellite. The pairing request timed out.")
        XCTAssertEqual(failureText(.repairNeeded), "This satellite no longer recognizes this device. Re-pair needed.")
        XCTAssertEqual(failureText(.unreachable(detail: "timeout")), "Server unreachable — has it moved networks? (timeout)")
        XCTAssertEqual(failureText(.noSharedKey), "No shared key — re-pair needed")
        XCTAssertEqual(failureText(.badSessionMaterial), "Bad token from server")
        XCTAssertEqual(
            failureText(.sessionLinkFailed),
            "The satellite accepted, but the controller link would not open. Try again."
        )
        XCTAssertEqual(failureText(.controllerNotApplied), "Server could not apply the controller")
        XCTAssertEqual(failureText(.noServersFound), "No servers found — check your network")
        XCTAssertEqual(
            failureText(.localNetworkDenied),
            "macOS is blocking Dish from the local network. Check Privacy & Security › Local Network, or add the satellite by address."
        )
        XCTAssertEqual(
            failureText(.dishUpdateRequired),
            "This satellite needs a newer version of Dish. Update the app and retry."
        )
        XCTAssertEqual(
            failureText(.satelliteUpdateRequired),
            "This satellite is too old for this version of Dish. Update the satellite."
        )
    }

    func testAServerDetailIsShownAsItCame() {
        XCTAssertEqual(failureText(.sessionRefused(detail: "slot busy")), "Error: slot busy")
        XCTAssertEqual(failureText(.sessionRefused(detail: nil)), "Error: connection failed")
        XCTAssertEqual(failureText(.pairingRejected(detail: "wrong pin")), "wrong pin")
        XCTAssertEqual(failureText(.pairingRejected(detail: nil)), "Pairing failed")
    }
}
