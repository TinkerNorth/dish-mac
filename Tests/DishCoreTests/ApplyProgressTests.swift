// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// One binding apply as the overlay shows it: a host already in session
/// takes the PUT at once, one that is not waits for its link first and may
/// be cancelled only while it waits, a durable binding is done at once, and
/// a run ends exactly once.
final class ApplyProgressTests: XCTestCase {

    private let waiting = ApplyProgress.running(.binding)
    private let onHost = ApplyProgress.running(.applyingOnHost)

    func testALiveHostTakesThePutAtOnce() {
        XCTAssertEqual(reduceApply(.idle, .started(.hostLive)), onHost)
    }

    func testAHostWithoutASessionWaitsForItsLinkFirst() {
        XCTAssertEqual(reduceApply(.idle, .started(.waitingForLink)), waiting)
    }

    func testADurableBindingIsDoneAtOnce() {
        XCTAssertEqual(reduceApply(.idle, .started(.durable)), .done)
    }

    func testTheLinkComingUpSendsThePut() {
        XCTAssertEqual(reduceApply(waiting, .putSent), onHost)
        XCTAssertEqual(reduceApply(onHost, .putSent), onHost, "a second word of the link changes nothing")
    }

    func testTheHostConfirmingEndsTheRunDone() {
        XCTAssertEqual(reduceApply(onHost, .hostConfirmed), .done)
        XCTAssertEqual(reduceApply(waiting, .hostConfirmed), .done, "a session PUT that carried it confirms it too")
    }

    func testTheHostRefusingEndsTheRunRejected() {
        XCTAssertEqual(reduceApply(onHost, .hostRejected), .failed(.rejected))
    }

    func testTheBudgetSpentEndsTheRunUnreachable() {
        XCTAssertEqual(reduceApply(waiting, .budgetSpent), .failed(.hostUnreachable))
        XCTAssertEqual(reduceApply(onHost, .budgetSpent), .failed(.hostUnreachable))
    }

    func testThePadLeavingEndsTheRun() {
        XCTAssertEqual(reduceApply(onHost, .padGone), .failed(.padGone))
        XCTAssertEqual(reduceApply(.idle, .padGone), .failed(.padGone), "a pad gone before the start fails the start")
    }

    func testCancelIsHonouredOnlyBeforeThePut() {
        XCTAssertEqual(reduceApply(waiting, .cancelled), .failed(.cancelled))
        XCTAssertEqual(reduceApply(onHost, .cancelled), onHost, "the REST round trip cannot be half applied")
        XCTAssertTrue(applyCancellable(waiting))
        XCTAssertFalse(applyCancellable(onHost))
        XCTAssertFalse(applyCancellable(.idle))
        XCTAssertFalse(applyCancellable(.done))
    }

    func testAnEndedRunIgnoresLateWords() {
        let ended: [ApplyProgress] = [.done, .failed(.rejected)]
        let late: [ApplyEvent] = [.putSent, .hostConfirmed, .hostRejected, .budgetSpent, .padGone, .cancelled]
        for end in ended {
            for event in late {
                XCTAssertEqual(reduceApply(end, event), end, "\(event) after \(end)")
            }
        }
    }

    func testAnIdleRunIgnoresEverythingButAStart() {
        let words: [ApplyEvent] = [.putSent, .hostConfirmed, .hostRejected, .budgetSpent, .cancelled, .dismissed]
        for event in words {
            XCTAssertEqual(reduceApply(.idle, event), .idle, "\(event)")
        }
    }

    func testDismissingAnEndedRunReturnsToIdle() {
        XCTAssertEqual(reduceApply(.done, .dismissed), .idle)
        XCTAssertEqual(reduceApply(.failed(.cancelled), .dismissed), .idle)
        XCTAssertEqual(reduceApply(onHost, .dismissed), onHost, "a running apply is not dismissed")
    }

    func testANewStartReplacesAnEndedRun() {
        XCTAssertEqual(reduceApply(.failed(.rejected), .started(.hostLive)), onHost)
        XCTAssertEqual(reduceApply(onHost, .started(.durable)), onHost, "one run at a time")
    }

    func testOnlyARunningApplyIsInFlight() {
        XCTAssertTrue(applyInFlight(waiting))
        XCTAssertTrue(applyInFlight(onHost))
        XCTAssertFalse(applyInFlight(.idle))
        XCTAssertFalse(applyInFlight(.done))
        XCTAssertFalse(applyInFlight(.failed(.padGone)))
    }
}
