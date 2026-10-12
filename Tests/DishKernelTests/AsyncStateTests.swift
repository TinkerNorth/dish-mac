// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import XCTest

private enum FetchFailure: Equatable {
    case unreachable
}

private typealias Fetch = AsyncState<[String], FetchFailure>

final class AsyncStateTests: XCTestCase {

    func testIdleHasNoDataNoErrorAndIsNotStale() {
        let state = Fetch.idle
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.data)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.stale)
    }

    func testAFreshLoadShowsNothingMeanwhile() {
        let state = Fetch.loadingFresh
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.data)
        XCTAssertFalse(state.stale)
    }

    func testSuccessCarriesTheValueAndIsNotStale() {
        let state = Fetch.idle.toSuccess(["a"])
        XCTAssertTrue(state.isSuccess)
        XCTAssertEqual(state.data, ["a"])
        XCTAssertFalse(state.stale)
    }

    func testARefreshKeepsThePreviousValueAsStale() {
        let state = Fetch.idle.toSuccess(["a"]).toLoading()
        XCTAssertTrue(state.isLoading)
        XCTAssertEqual(state.data, ["a"])
        XCTAssertTrue(state.stale)
    }

    func testALoadFromIdleHasNothingToKeep() {
        let state = Fetch.idle.toLoading()
        XCTAssertNil(state.data)
        XCTAssertFalse(state.stale)
    }

    func testAFailedRefreshKeepsThePreviousValueAndCarriesTheReason() {
        let state = Fetch.idle.toSuccess(["a"]).toLoading().toError(.unreachable)
        XCTAssertTrue(state.isError)
        XCTAssertEqual(state.error, .unreachable)
        XCTAssertEqual(state.data, ["a"])
        XCTAssertTrue(state.stale)
    }

    func testAFailedFirstLoadHasNoDataAndIsNotStale() {
        let state = Fetch.loadingFresh.toError(.unreachable)
        XCTAssertNil(state.data)
        XCTAssertFalse(state.stale)
    }

    func testARevalidationConfirmsThePreviousValueAsStaleSuccess() {
        let state = Fetch.idle.toSuccess(["a"]).toLoading().toRevalidated()
        XCTAssertTrue(state.isSuccess)
        XCTAssertEqual(state.data, ["a"])
        XCTAssertTrue(state.stale)
    }

    func testASuccessAfterAnErrorClearsTheError() {
        let state = Fetch.loadingFresh.toError(.unreachable).toSuccess(["b"])
        XCTAssertNil(state.error)
        XCTAssertEqual(state.data, ["b"])
    }

    func testEqualityCoversEveryField() {
        XCTAssertEqual(Fetch.idle.toSuccess(["a"]), Fetch.idle.toSuccess(["a"]))
        XCTAssertNotEqual(Fetch.idle.toSuccess(["a"]), Fetch.idle.toSuccess(["a"]).toRevalidated())
    }
}
