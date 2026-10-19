// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import XCTest
@testable import Dish

/// A failure reaches the user once: one keyed error toast, replaced by the
/// next, and none while a sheet shows the failure under its own field.
@MainActor
final class FailureNotifierTests: XCTestCase {

    func testAFailureIsOneKeyedErrorToastAndTheNextReplacesIt() {
        let center = DishNotificationCenter()
        let failures = PassthroughSubject<ConnectionFailure, Never>()
        let notifier = FailureNotifier()
        notifier.bind(failures: failures.eraseToAnyPublisher(), shownInline: { false }, center: center)

        failures.send(.noServersFound)
        XCTAssertEqual(center.state.map(\.title), [failureText(.noServersFound)])
        XCTAssertEqual(center.state.first?.severity, .error)
        XCTAssertEqual(center.state.first?.key, "wifi.failure")

        failures.send(.sessionLinkFailed)
        XCTAssertEqual(center.state.map(\.title), [failureText(.sessionLinkFailed)], "the same key replaces, never stacks")
    }

    func testAFailureASheetShowsInlineIsNotToastedAsWell() {
        let center = DishNotificationCenter()
        let failures = PassthroughSubject<ConnectionFailure, Never>()
        let pairingSheetUp = LockedFlag()
        let notifier = FailureNotifier()
        notifier.bind(failures: failures.eraseToAnyPublisher(), shownInline: { pairingSheetUp.value }, center: center)

        pairingSheetUp.value = true
        failures.send(.pairingRejected(detail: nil))
        XCTAssertEqual(center.state, [], "the pairing sheet says it under the PIN field")

        pairingSheetUp.value = false
        failures.send(.pairingRejected(detail: nil))
        XCTAssertEqual(center.state.map(\.title), [failureText(.pairingRejected(detail: nil))])
    }
}

/// A flag the test flips between sends; a closure cannot capture a plain
/// `var` from a `@MainActor` test and stay `Sendable`.
private final class LockedFlag: @unchecked Sendable {
    var value = false
}
