// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The hot path's "tell me" protocol: a raised bit posts one event per
/// source on the first change, an unchanged report never spends it, and
/// only the routed source is published.
final class PadGateTests: XCTestCase {

    private let posted = LockedBox<[InputSource]>([])

    private func gate() -> PadGate {
        let posted = posted
        return PadGate(key: "pad") { _, source in posted.set(posted.get() + [source]) }
    }

    func testNothingIsPostedWhileTheMainActorAsksForNothing() {
        let pad = gate()
        XCTAssertFalse(pad.pass(.direct, changed: true))
        XCTAssertEqual(posted.get(), [])
    }

    func testARaisedBitPostsOnceForEachSourceHoweverManyChangesArrive() {
        let pad = gate()
        pad.requestEvents()
        for _ in 0 ..< 5 {
            _ = pad.pass(.direct, changed: true) // Only the posts are under test here.
            _ = pad.pass(.standard, changed: true) // Only the posts are under test here.
        }
        XCTAssertEqual(posted.get(), [.direct, .standard])
        XCTAssertFalse(pad.awaitsEvent(.direct))
        XCTAssertFalse(pad.awaitsEvent(.standard))
    }

    func testAnUnchangedReportDoesNotSpendTheBit() {
        let pad = gate()
        pad.requestEvents()
        _ = pad.pass(.direct, changed: false) // Only the posts are under test here.
        XCTAssertEqual(posted.get(), [])
        XCTAssertTrue(pad.awaitsEvent(.direct), "the first real change still tells")
    }

    func testCancellingLowersBothBits() {
        let pad = gate()
        pad.requestEvents()
        pad.cancelEvents()
        _ = pad.pass(.direct, changed: true) // Only the posts are under test here.
        XCTAssertEqual(posted.get(), [])
    }

    func testOnlyTheRoutedSourceIsPublished() {
        let pad = gate()
        XCTAssertNil(pad.routed)
        pad.route(.direct)
        XCTAssertTrue(pad.pass(.direct, changed: false))
        XCTAssertFalse(pad.pass(.standard, changed: false))
        XCTAssertTrue(pad.forwards(.direct))
        XCTAssertFalse(pad.forwards(.standard))
        pad.route(nil)
        XCTAssertFalse(pad.pass(.direct, changed: false), "a pad routed nowhere publishes nothing")
    }

    func testACaptureWishIsTakenOnceWhileTheWalkStaysOpen() {
        let pad = gate()
        XCTAssertFalse(pad.capturing)
        XCTAssertFalse(pad.takeCaptureWish())
        pad.listenForCapture()
        XCTAssertTrue(pad.capturing)
        XCTAssertTrue(pad.takeCaptureWish())
        XCTAssertFalse(pad.takeCaptureWish(), "one raw change per wish")
        XCTAssertTrue(pad.capturing, "the walk stays open between its steps")
        pad.listenForCapture()
        pad.closeCapture()
        XCTAssertFalse(pad.capturing)
        XCTAssertFalse(pad.takeCaptureWish(), "closing drops a pending wish")
    }
}
