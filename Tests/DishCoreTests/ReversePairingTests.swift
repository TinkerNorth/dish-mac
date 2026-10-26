// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Operator-approved pairing as executable rules: what one status poll
/// means, and what the poll does next. The desktops' `ReversePairing.h` and
/// the approval half of their `RestOutcome.h`.
final class ReversePairingTests: XCTestCase {

    private static let key = String(repeating: "ab", count: 32)
    private static let deadlineMs = 120_000

    private func reply(_ status: String, key: String? = nil) -> ApprovalReply {
        ApprovalReply(reachable: true, status: status, sharedKey: key)
    }

    // MARK: - classifyApproval

    func testApprovedWithAFullHexKeyIsApproved() {
        let verdict = classifyApproval(reply("approved", key: Self.key), sawPending: true)
        XCTAssertEqual(verdict, .approved(sharedKeyHex: Self.key))
        let upper = String(repeating: "AB", count: 32)
        XCTAssertEqual(classifyApproval(reply("approved", key: upper), sawPending: false), .approved(sharedKeyHex: upper))
    }

    func testApprovedWithoutAUsableKeyIsStillPending() {
        XCTAssertEqual(classifyApproval(reply("approved"), sawPending: true), .pending, "no key")
        XCTAssertEqual(classifyApproval(reply("approved", key: "abcd"), sawPending: true), .pending, "a short key")
        let nonHex = String(repeating: "zz", count: 32)
        XCTAssertEqual(classifyApproval(reply("approved", key: nonHex), sawPending: true), .pending, "a non-hex key")
        let long = Self.key + "ab"
        XCTAssertEqual(classifyApproval(reply("approved", key: long), sawPending: true), .pending, "a long key")
    }

    func testAKeyOnAnyOtherStatusIsNotAnApproval() {
        XCTAssertEqual(classifyApproval(reply("pending", key: Self.key), sawPending: true), .pending)
    }

    func testNoneAfterAPendingIsTheOperatorsDecline() {
        XCTAssertEqual(classifyApproval(reply("none"), sawPending: true), .declined)
    }

    func testNoneBeforeAnyPendingKeepsWaiting() {
        XCTAssertEqual(classifyApproval(reply("none"), sawPending: false), .pending)
    }

    func testTheLegacyDeniedWordIsADeclineEitherWay() {
        XCTAssertEqual(classifyApproval(reply("denied"), sawPending: false), .declined)
        XCTAssertEqual(classifyApproval(reply("denied"), sawPending: true), .declined)
    }

    func testPendingAndUnknownWordsKeepWaiting() {
        XCTAssertEqual(classifyApproval(reply("pending"), sawPending: false), .pending)
        XCTAssertEqual(classifyApproval(reply(""), sawPending: true), .pending)
        XCTAssertEqual(classifyApproval(reply("future-state"), sawPending: true), .pending)
    }

    func testATransportFailureIsUnreachableWhateverItCarried() {
        let blip = ApprovalReply(reachable: false, status: "approved", sharedKey: Self.key)
        XCTAssertEqual(classifyApproval(blip, sawPending: true), .unreachable)
        XCTAssertEqual(classifyApproval(ApprovalReply(reachable: false), sawPending: false), .unreachable)
    }

    // MARK: - nextReversePairingAction

    func testAnApprovalIsActedOnEvenPastTheDeadline() {
        for elapsed in [0, Self.deadlineMs, Self.deadlineMs + 1] {
            let action = nextReversePairingAction(
                verdict: .approved(sharedKeyHex: Self.key),
                elapsedMs: elapsed,
                deadlineMs: Self.deadlineMs
            )
            XCTAssertEqual(action, .approve(sharedKeyHex: Self.key), "at \(elapsed) ms")
        }
    }

    func testADeclineEndsThePollWhateverTheClock() {
        for elapsed in [0, Self.deadlineMs - 1, Self.deadlineMs] {
            let action = nextReversePairingAction(verdict: .declined, elapsedMs: elapsed, deadlineMs: Self.deadlineMs)
            XCTAssertEqual(action, .decline, "at \(elapsed) ms")
        }
    }

    func testPendingKeepsPollingUntilTheInclusiveDeadline() {
        let before = nextReversePairingAction(verdict: .pending, elapsedMs: Self.deadlineMs - 1, deadlineMs: Self.deadlineMs)
        XCTAssertEqual(before, .keepPolling)
        let at = nextReversePairingAction(verdict: .pending, elapsedMs: Self.deadlineMs, deadlineMs: Self.deadlineMs)
        XCTAssertEqual(at, .timeOut, "the budget is spent at the deadline itself")
        let after = nextReversePairingAction(verdict: .pending, elapsedMs: Self.deadlineMs + 1, deadlineMs: Self.deadlineMs)
        XCTAssertEqual(after, .timeOut)
    }

    func testATransportBlipKeepsPollingAndOnlyTheDeadlineEndsIt() {
        let early = nextReversePairingAction(verdict: .unreachable, elapsedMs: 2000, deadlineMs: Self.deadlineMs)
        XCTAssertEqual(early, .keepPolling, "a blip never aborts the poll")
        let late = nextReversePairingAction(verdict: .unreachable, elapsedMs: Self.deadlineMs - 1, deadlineMs: Self.deadlineMs)
        XCTAssertEqual(late, .keepPolling)
        let spent = nextReversePairingAction(verdict: .unreachable, elapsedMs: Self.deadlineMs, deadlineMs: Self.deadlineMs)
        XCTAssertEqual(spent, .timeOut)
    }

    // MARK: - The shared key's shape

    func testASharedKeyIsSixtyFourHexDigitsOfEitherCase() {
        XCTAssertTrue(isSharedKeyHex(Self.key))
        XCTAssertTrue(isSharedKeyHex(String(repeating: "0F", count: 32)))
        XCTAssertFalse(isSharedKeyHex(String(Self.key.dropLast())))
        XCTAssertFalse(isSharedKeyHex(Self.key + "a"))
        XCTAssertFalse(isSharedKeyHex(String(repeating: "g0", count: 32)))
        XCTAssertFalse(isSharedKeyHex(""))
    }
}
