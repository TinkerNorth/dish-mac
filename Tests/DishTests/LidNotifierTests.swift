// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import Dish

/// A lid that closed on a stream is one keyed info toast, never a stack.
@MainActor
final class LidNotifierTests: XCTestCase {

    func testALidThatPausedAStreamIsOneKeyedInfoToast() {
        let center = DishNotificationCenter()
        let lidPaused = PassthroughSubject<Void, Never>()
        let notifier = LidNotifier()
        notifier.bind(lidPausedStreaming: lidPaused.eraseToAnyPublisher(), center: center)
        XCTAssertEqual(center.state, [])

        lidPaused.send(())
        XCTAssertEqual(center.state.map(\.title), ["Streaming paused while the lid was closed"])
        XCTAssertEqual(center.state.first?.severity, .info)
        XCTAssertEqual(center.state.first?.key, "power.lid")

        lidPaused.send(())
        XCTAssertEqual(center.state.count, 1, "the same key replaces, never stacks")
    }
}
