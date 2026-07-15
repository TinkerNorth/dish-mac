// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The REST outcome classifier — the contract's error model (§Error model,
// §hmacProof) as executable rules: terminal 401 (either machine code) and
// 409, retryable transport failure / 503 / 5xx. Ports the dish-linux
// Network/RestOutcome.h semantics (dish-windows reducer test port).

import DishCore
import XCTest

final class RestOutcomeTests: XCTestCase {

    func testTransportFailureIsUnreachable() {
        // Status 0 is the synthesised-failure sentinel: the transport never
        // produced a response.
        XCTAssertEqual(classifyRest(RestReply(status: 0, bodyParsed: false)), .unreachable)
        // A status with an unparseable body is equally unusable.
        XCTAssertEqual(classifyRest(RestReply(status: 200, bodyParsed: false)), .unreachable)
    }

    func testTwoHundredsWithABodyAreOk() {
        XCTAssertEqual(classifyRest(RestReply(status: 200, bodyParsed: true)), .ok)
        XCTAssertEqual(classifyRest(RestReply(status: 204, bodyParsed: true)), .ok)
        XCTAssertEqual(classifyRest(RestReply(status: 299, bodyParsed: true)), .ok)
    }

    func testFourOhOneIsUnauthorizedForBothMachineCodes() {
        // NOT_PAIRED and BAD_PROOF both surface as unauthorized — both
        // terminal (contract §hmacProof).
        XCTAssertEqual(
            classifyRest(RestReply(status: 401, bodyParsed: true, code: ProtocolConstants.authCodeNotPaired)),
            .unauthorized
        )
        XCTAssertEqual(
            classifyRest(RestReply(status: 401, bodyParsed: true, code: ProtocolConstants.authCodeBadProof)),
            .unauthorized
        )
        XCTAssertEqual(classifyRest(RestReply(status: 401, bodyParsed: true)), .unauthorized)
    }

    func testFourOhNineIsVersionMismatch() {
        XCTAssertEqual(classifyRest(RestReply(status: 409, bodyParsed: true)), .versionMismatch)
    }

    func testFiveOhThreeIsShuttingDown() {
        XCTAssertEqual(classifyRest(RestReply(status: 503, bodyParsed: true)), .shuttingDown)
    }

    func testOtherStatusesAreServerErrors() {
        XCTAssertEqual(classifyRest(RestReply(status: 400, bodyParsed: true)), .serverError)
        XCTAssertEqual(classifyRest(RestReply(status: 404, bodyParsed: true)), .serverError)
        XCTAssertEqual(classifyRest(RestReply(status: 500, bodyParsed: true)), .serverError)
    }

    func testTerminalAndRetryablePartitionTheVerdicts() {
        // Terminal: stop the retry loop, surface a user decision.
        XCTAssertTrue(restVerdictTerminal(.unauthorized))
        XCTAssertTrue(restVerdictTerminal(.versionMismatch))
        XCTAssertFalse(restVerdictTerminal(.ok))
        XCTAssertFalse(restVerdictTerminal(.shuttingDown))
        XCTAssertFalse(restVerdictTerminal(.unreachable))
        XCTAssertFalse(restVerdictTerminal(.serverError))
        // Retryable: feed the exponential backoff schedule.
        XCTAssertTrue(restVerdictRetryable(.unreachable))
        XCTAssertTrue(restVerdictRetryable(.shuttingDown))
        XCTAssertTrue(restVerdictRetryable(.serverError))
        XCTAssertFalse(restVerdictRetryable(.ok))
        XCTAssertFalse(restVerdictRetryable(.unauthorized))
        XCTAssertFalse(restVerdictRetryable(.versionMismatch))
    }
}
