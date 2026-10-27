// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import Dish

/// A pad that keeps dropping is one keyed warning per burst, with the
/// connection hint under it.
@MainActor
final class PadNotifierTests: XCTestCase {

    func testABurstOfDropsIsOneKeyedWarningWithTheConnectionHint() {
        let center = DishNotificationCenter()
        let bursts = PassthroughSubject<String, Never>()
        let notifier = PadNotifier()
        notifier.bind(keepsDisconnecting: bursts.eraseToAnyPublisher(), center: center)
        XCTAssertEqual(center.state, [])

        bursts.send("Nintendo N64 Online Controller")
        XCTAssertEqual(center.state.map(\.title), ["Nintendo N64 Online Controller keeps disconnecting"])
        XCTAssertEqual(center.state.first?.body, "Check the cable or the Bluetooth connection, then try again")
        XCTAssertEqual(center.state.first?.severity, .warn)
        XCTAssertEqual(center.state.first?.key, "pad.disconnects.Nintendo N64 Online Controller")

        bursts.send("Nintendo N64 Online Controller")
        XCTAssertEqual(center.state.count, 1, "the same pad's next burst replaces, never stacks")
        bursts.send("Pro Controller")
        XCTAssertEqual(center.state.count, 2, "another pad has its own")
    }
}
