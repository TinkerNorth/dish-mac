// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Pins the `PairingClient.classify` contract. Mirrors the
/// `unreachable-vs-auth` distinction that dish-android PR #43 introduced in
/// `SatelliteConnectionManager`. These cases are what stops a moved server
/// from trapping the user behind an unanswerable PIN prompt.
final class PairingClientClassifyTests: XCTestCase {

    func testSuccessRequiresOkAndSharedKey() {
        var r = PairResponse()
        r.ok = true
        r.sharedKey = "abcd"
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .success(sharedKeyHex: "abcd"))
    }

    func testReachableButNotOkIsAuthRequired() {
        var r = PairResponse()
        r.ok = false
        r.reachable = true
        r.error = "bad pin"
        XCTAssertEqual(PairingClient.classify(r), .authRequired)
    }

    func testUnreachableSurfacesNetworkError() {
        var r = PairResponse()
        r.ok = false
        r.reachable = false
        r.error = "connect timeout"
        XCTAssertEqual(
            PairingClient.classify(r),
            .unreachable("connect timeout")
        )
    }

    func testUnreachableWithNoErrorFallsBackToDefaultMessage() {
        var r = PairResponse()
        r.ok = false
        r.reachable = false
        XCTAssertEqual(
            PairingClient.classify(r),
            .unreachable("Server unreachable")
        )
    }

    func testOkButMissingSharedKeyIsNotSuccess() {
        // Defensive: a server that says ok=true but forgets to send a key
        // should fall through to authRequired (since we did reach it), not
        // success. Otherwise we'd cache an empty string as the shared key
        // and silently break every subsequent reconnect.
        var r = PairResponse()
        r.ok = true
        r.sharedKey = nil
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .authRequired)
    }

    func testEmptySharedKeyIsNotSuccess() {
        var r = PairResponse()
        r.ok = true
        r.sharedKey = ""
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .authRequired)
    }

    // MARK: - Protocol-1 arms (G5 / G16)

    func testConflictStatusIsVersionMismatchEvenWhenReachable() {
        // 409 must win over the generic reachable→authRequired fallthrough:
        // popping a PIN prompt for a protocol skew traps the user in a dance
        // that can never succeed (contract §Versioning).
        var r = PairResponse()
        r.ok = false
        r.reachable = true
        r.httpStatus = 409
        r.error = "protocol version unsupported"
        XCTAssertEqual(PairingClient.classify(r), .versionMismatch)
    }

    func testPendingResponseIsPendingApproval() {
        var r = PairResponse()
        r.ok = false
        r.pending = true
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .pendingApproval)
    }

    func testSuccessWinsOverPendingFlag() {
        // A key in hand is a key in hand, whatever else the body says.
        var r = PairResponse()
        r.ok = true
        r.pending = true
        r.sharedKey = "abcd"
        r.reachable = true
        XCTAssertEqual(PairingClient.classify(r), .success(sharedKeyHex: "abcd"))
    }

    // MARK: - Path-B status poll classification (ports dish-android PairingApproval)

    private func status(_ status: String, key: String? = nil) -> PairStatusResponse {
        var r = PairStatusResponse()
        r.ok = status == "approved"
        r.status = status
        r.sharedKey = key
        r.reachable = true
        return r
    }

    func testApprovedWithFullHexKeyIsApproved() {
        let key = String(repeating: "ab", count: 32)
        XCTAssertEqual(
            PairingClient.classifyStatus(status("approved", key: key)),
            .approved(sharedKeyHex: key)
        )
    }

    func testApprovedWithoutUsableKeyIsDeclined() {
        // Approved-but-malformed must never be mistaken for a usable key.
        XCTAssertEqual(PairingClient.classifyStatus(status("approved")), .declined)
        XCTAssertEqual(PairingClient.classifyStatus(status("approved", key: "abcd")), .declined)
        let nonHex = String(repeating: "zz", count: 32)
        XCTAssertEqual(PairingClient.classifyStatus(status("approved", key: nonHex)), .declined)
    }

    func testPendingKeepsPolling() {
        XCTAssertEqual(PairingClient.classifyStatus(status("pending")), .pending)
    }

    func testDeniedNoneAndUnknownStopPolling() {
        XCTAssertEqual(PairingClient.classifyStatus(status("denied")), .declined)
        XCTAssertEqual(PairingClient.classifyStatus(status("none")), .declined)
        XCTAssertEqual(PairingClient.classifyStatus(status("")), .declined)
        XCTAssertEqual(PairingClient.classifyStatus(status("future-state")), .declined)
    }

    // MARK: - Client PIN shape

    func testGeneratedClientPinIsFourDigits() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 32 {
            let pin = PairingClient.generateClientPin(using: &generator)
            XCTAssertEqual(pin.count, 4)
            XCTAssertTrue(pin.allSatisfy(\.isNumber), "non-digit in client PIN \(pin)")
        }
    }

    // MARK: - Decoded responses default to reachable=false

    func testJsonDecodeDefaultsReachableToFalse() throws {
        // PairResponse Decodable omits `reachable` so a fresh server response
        // decodes to reachable=false. PairingClient.pair flips it to true
        // after a successful decode; if we ever drop that flip, every pair
        // response would silently classify as unreachable.
        let json = Data(#"{"ok":true,"sharedKey":"deadbeef"}"#.utf8)
        let r = try JSONDecoder().decode(PairResponse.self, from: json)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.sharedKey, "deadbeef")
        XCTAssertFalse(r.reachable)
    }
}
