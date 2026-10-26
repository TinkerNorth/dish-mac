// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishEngine
import XCTest
@testable import Dish

/// A failure reaches the user once: one keyed error toast, replaced by the
/// next. Which failures arrive is the model's call (the pairing card keeps
/// its own), so the notifier toasts every one it is handed.
@MainActor
final class FailureNotifierTests: XCTestCase {

    func testAFailureIsOneKeyedErrorToastAndTheNextReplacesIt() {
        let center = DishNotificationCenter()
        let failures = PassthroughSubject<ConnectionFailure, Never>()
        let notifier = FailureNotifier()
        notifier.bind(failures: failures.eraseToAnyPublisher(), center: center)

        failures.send(.noServersFound)
        XCTAssertEqual(center.state.map(\.title), [failureText(.noServersFound)])
        XCTAssertEqual(center.state.first?.severity, .error)
        XCTAssertEqual(center.state.first?.key, "wifi.failure")

        failures.send(.sessionLinkFailed)
        XCTAssertEqual(center.state.map(\.title), [failureText(.sessionLinkFailed)], "the same key replaces, never stacks")
    }

    func testEveryFailureHandedOverIsToastedAPairingOneIncluded() {
        let center = DishNotificationCenter()
        let failures = PassthroughSubject<ConnectionFailure, Never>()
        let notifier = FailureNotifier()
        notifier.bind(failures: failures.eraseToAnyPublisher(), center: center)

        failures.send(.approvalDeclined)
        XCTAssertEqual(center.state.map(\.title), [failureText(.approvalDeclined)], "no blanket hush while a card is open")
    }
}
