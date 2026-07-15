// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// SESSION_CLOSE (0x000F) reason byte → teardown action, and the reason-byte
// values themselves (contract §UDP messages / §Session-close notify). Ports
// dish-linux test_close_notify.cpp.

import XCTest
import DishCore

final class CloseNotifyTests: XCTestCase {

    func testCloseReasonMapsToTheRightTeardownAction() {
        // unpaired: trust revoked — drop the key and stop retrying.
        XCTAssertEqual(closeActionForReason(.unpaired), .dropKeyAndStale)
        // replaced: a newer PUT owns the session — stay down.
        XCTAssertEqual(closeActionForReason(.replaced), .stayDown)
        // shutdown / kicked: transient — reconnect on the backoff curve.
        XCTAssertEqual(closeActionForReason(.shutdown), .backoffRetry)
        XCTAssertEqual(closeActionForReason(.kicked), .backoffRetry)
    }

    func testAnUnknownFutureReasonByteDegradesToATransientRetry() {
        XCTAssertEqual(closeAction(forReasonByte: 0x7F), .backoffRetry)
    }

    func testRawReasonBytesRouteThroughTheSameLadder() {
        XCTAssertEqual(closeAction(forReasonByte: 0), .backoffRetry)
        XCTAssertEqual(closeAction(forReasonByte: 1), .backoffRetry)
        XCTAssertEqual(closeAction(forReasonByte: 2), .stayDown)
        XCTAssertEqual(closeAction(forReasonByte: 3), .dropKeyAndStale)
    }

    func testCloseReasonBytesMatchTheContract() {
        XCTAssertEqual(CloseReason.shutdown.rawValue, 0)
        XCTAssertEqual(CloseReason.kicked.rawValue, 1)
        XCTAssertEqual(CloseReason.replaced.rawValue, 2)
        XCTAssertEqual(CloseReason.unpaired.rawValue, 3)
        XCTAssertEqual(closeReasonName(.unpaired), "unpaired")
        XCTAssertEqual(closeReasonName(.kicked), "kicked")
        XCTAssertEqual(closeReasonName(.replaced), "replaced")
        XCTAssertEqual(closeReasonName(.shutdown), "shutdown")
        // Unknown bytes read as "shutdown" (the C++ default arm).
        XCTAssertEqual(closeReasonName(forReasonByte: 0x7F), "shutdown")
    }
}
