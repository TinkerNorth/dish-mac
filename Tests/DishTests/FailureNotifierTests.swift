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
        notifier.bind(failures: failures.eraseToAnyPublisher(), center: center, open: ignoreURL)

        failures.send(.noServersFound)
        XCTAssertEqual(center.state.map(\.title), [failureText(.noServersFound)])
        XCTAssertEqual(center.state.first?.severity, .error)
        XCTAssertEqual(center.state.first?.key, "wifi.failure")

        failures.send(.sessionLinkFailed)
        XCTAssertEqual(center.state.map(\.title), [failureText(.sessionLinkFailed)], "the same key replaces, never stacks")
    }

    private var opened: [URL] = []

    private func ignoreURL(_: URL) {}

    private func recordURL(_ url: URL) {
        opened.append(url)
    }

    func testARefusedLocalNetworkToastOpensSystemSettings() throws {
        let center = DishNotificationCenter()
        let failures = PassthroughSubject<ConnectionFailure, Never>()
        let notifier = FailureNotifier()
        notifier.bind(failures: failures.eraseToAnyPublisher(), center: center, open: recordURL)

        failures.send(.localNetworkDenied)
        let action = try XCTUnwrap(center.state.first?.action)
        XCTAssertEqual(action.label, "Open System Settings")
        action.handler()
        XCTAssertEqual(opened, [URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")])

        failures.send(.noServersFound)
        XCTAssertNil(center.state.first?.action, "any other failure has no way out")
    }

    func testEveryFailureHandedOverIsToastedAPairingOneIncluded() {
        let center = DishNotificationCenter()
        let failures = PassthroughSubject<ConnectionFailure, Never>()
        let notifier = FailureNotifier()
        notifier.bind(failures: failures.eraseToAnyPublisher(), center: center, open: ignoreURL)

        failures.send(.approvalDeclined)
        XCTAssertEqual(center.state.map(\.title), [failureText(.approvalDeclined)], "no blanket hush while a card is open")
    }
}
