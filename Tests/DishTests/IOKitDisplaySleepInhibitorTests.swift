// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Pins the production `IOKitDisplaySleepInhibitor` against the real IOKit
/// API. `ScreenWakeControllerTests` already covers the abstract
/// `DisplaySleepInhibitor` contract via a fake; this file exercises the
/// concrete impl too so the lifecycle isn't a "checked at runtime only"
/// surface.
///
/// `IOPMAssertionCreateWithName` is harmless to flip from a test — it's an
/// in-process call that registers an entry with the kernel power manager,
/// and `IOPMAssertionRelease` retires it. macOS CI runners do not have an
/// active display session but the assertion API still works (it's used by
/// command-line tools like `caffeinate` without a GUI).
final class IOKitDisplaySleepInhibitorTests: XCTestCase {

    func testStartsUnheld() {
        let inh = IOKitDisplaySleepInhibitor()
        XCTAssertFalse(inh.isHeld)
    }

    func testAcquireFlipsHeldReleaseFlipsItBack() {
        let inh = IOKitDisplaySleepInhibitor()
        inh.acquire(reason: "test")
        XCTAssertTrue(inh.isHeld)
        inh.release()
        XCTAssertFalse(inh.isHeld)
    }

    func testAcquireIsIdempotent() {
        let inh = IOKitDisplaySleepInhibitor()
        inh.acquire(reason: "first")
        XCTAssertTrue(inh.isHeld)
        // Second acquire while already held must be a no-op — held stays
        // true and we don't leak a second IOPMAssertion id (which would
        // never get released on the destruction path).
        inh.acquire(reason: "second")
        XCTAssertTrue(inh.isHeld)
        inh.release()
        XCTAssertFalse(inh.isHeld)
    }

    func testReleaseIsIdempotent() {
        let inh = IOKitDisplaySleepInhibitor()
        // Release on a fresh, unheld inhibitor must be a no-op (calling
        // IOPMAssertionRelease(0) is itself a no-op but we shouldn't even
        // make the syscall).
        inh.release()
        XCTAssertFalse(inh.isHeld)

        inh.acquire(reason: "test")
        inh.release()
        inh.release() // Double-release: still no-op.
        XCTAssertFalse(inh.isHeld)
    }

    func testReacquiresCleanlyAfterRelease() {
        let inh = IOKitDisplaySleepInhibitor()
        inh.acquire(reason: "first stream")
        inh.release()
        inh.acquire(reason: "second stream")
        XCTAssertTrue(inh.isHeld)
        inh.release()
        XCTAssertFalse(inh.isHeld)
    }

    func testDeinitReleasesAHeldAssertion() {
        // RAII: dropping the inhibitor while held must release the
        // assertion so a forgotten release on shutdown doesn't pin the
        // display awake until the next reboot. The IOKit API has no
        // process-wide "is assertion type X active?" query we can poll
        // from inside the test, so we pin the observable proxy: after
        // the held inhibitor goes out of scope, a fresh instance starts
        // in the unheld state and we can still acquire+release it
        // cleanly (i.e. we didn't corrupt our own bookkeeping).
        do {
            let inh = IOKitDisplaySleepInhibitor()
            inh.acquire(reason: "dies on scope exit")
            XCTAssertTrue(inh.isHeld)
            // deinit runs here.
        }
        let next = IOKitDisplaySleepInhibitor()
        XCTAssertFalse(next.isHeld)
        next.acquire(reason: "after dead instance")
        XCTAssertTrue(next.isHeld)
        next.release()
    }
}
