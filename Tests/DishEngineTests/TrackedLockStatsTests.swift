// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest
@testable import DishEngine

/// What a LOCK_STATS build counts: each acquisition under the role of the
/// queue or thread that took it, a wait behind a holder, the hold, the lock
/// taken inside another, and the locks held across a blocking call.
final class TrackedLockStatsTests: XCTestCase {

    #if LOCK_STATS
    func testAnAcquisitionCountsUnderItsQueuesOrItsThreadsRole() {
        let probe = NamedLock("test.roles")
        let input = ThreadRole.input.queue(label: "test.roles.input", qos: .userInteractive)
        runAndWait(on: input) { probe.cycle(times: 3) }
        runOnThread(as: .hidReader) { probe.cycle(times: 2) }
        runAndWait(on: DispatchQueue(label: "test.roles.unmarked")) { probe.cycle(times: 4) }
        probe.cycle(times: 1)
        let snapshot = lockStatsSnapshot()
        XCTAssertEqual(snapshot.counters("test.roles", .input).acquisitions, 3)
        XCTAssertEqual(snapshot.counters("test.roles", .hidReader).acquisitions, 2)
        XCTAssertEqual(snapshot.counters("test.roles", .other).acquisitions, 4)
        XCTAssertEqual(snapshot.counters("test.roles", .main).acquisitions, 1)
        XCTAssertEqual(snapshot.acquired(by: .receive).filter { $0.hasPrefix("test.") }, [])
    }

    func testAWaitBehindAHolderCountsAsContendedWithItsWait() {
        let probe = NamedLock("test.contended")
        let held = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            probe.take()
            held.signal()
            Thread.sleep(forTimeInterval: 0.05)
            probe.give()
            finished.signal()
        }.start()
        held.wait()
        probe.take()
        probe.give()
        finished.wait()
        let mainCounts = lockStatsSnapshot().counters("test.contended", .main)
        XCTAssertEqual(mainCounts.acquisitions, 1)
        XCTAssertEqual(mainCounts.contended, 1, "the main thread found the lock held")
        XCTAssertGreaterThan(mainCounts.waitMaxNs, 1_000_000, "and waited for the holder's sleep")
        XCTAssertEqual(lockStatsSnapshot().counters("test.contended", .other).contended, 0)
    }

    func testAnNSLockCountsItsContentionToo() {
        let probe = NamedMutex("test.contendedMutex")
        let held = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            probe.take()
            held.signal()
            Thread.sleep(forTimeInterval: 0.05)
            probe.give()
            finished.signal()
        }.start()
        held.wait()
        probe.take()
        probe.give()
        finished.wait()
        XCTAssertEqual(lockStatsSnapshot().counters("test.contendedMutex", .main).contended, 1)
    }

    func testTheHoldIsTheTimeBetweenTakingAndGiving() {
        let probe = NamedLock("test.hold")
        probe.take()
        Thread.sleep(forTimeInterval: 0.005)
        probe.give()
        let counts = lockStatsSnapshot().counters("test.hold", .main)
        XCTAssertGreaterThanOrEqual(counts.holdMaxNs, 4_000_000)
        XCTAssertEqual(counts.holdHistogram.reduce(0, +), 1)
        XCTAssertEqual(counts.contended, 0)
    }

    func testALockTakenInsideAnotherIsANestingEdgeInThatOrderOnly() {
        let outer = NamedLock("test.nestOuter")
        let inner = NamedLock("test.nestInner")
        outer.take()
        inner.take()
        inner.give()
        outer.give()
        inner.cycle(times: 1)
        let edges = lockStatsSnapshot().edges
        XCTAssertEqual(edges[LockPair("test.nestOuter", "test.nestInner")], 1)
        XCTAssertNil(edges[LockPair("test.nestInner", "test.nestOuter")])
    }

    func testABlockingCallCountsEveryLockHeldAcrossIt() {
        let outer = NamedLock("test.blockingOuter")
        outer.take()
        blockingRegion("test.blockingCall")
        outer.give()
        blockingRegion("test.blockingCall")
        let snapshot = lockStatsSnapshot()
        XCTAssertEqual(snapshot.blocking[LockPair("test.blockingCall", "test.blockingOuter")], 1)
        XCTAssertEqual(snapshot.regions["test.blockingCall"], 2)
    }

    func testAResetStartsEveryCountOver() {
        let probe = NamedLock("test.reset")
        probe.cycle(times: 2)
        XCTAssertEqual(lockStatsSnapshot().counters("test.reset", .main).acquisitions, 2)
        resetLockStats()
        XCTAssertEqual(lockStatsSnapshot().counters("test.reset", .main).acquisitions, 0)
        probe.cycle(times: 1)
        XCTAssertEqual(lockStatsSnapshot().counters("test.reset", .main).acquisitions, 1)
    }

    private func runAndWait(on queue: DispatchQueue, _ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            body()
            done.signal()
        }
        done.wait()
    }

    private func runOnThread(as role: ThreadRole, _ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            role.enterThread()
            body()
            done.signal()
        }.start()
        done.wait()
    }
    #else
    func testTheCountsNeedTheLockStatsBuild() throws {
        throw XCTSkip("built without LOCK_STATS; run swift test -Xswiftc -DLOCK_STATS")
    }
    #endif
}

/// An unfair lock any thread can take, as its owner would.
private final class NamedLock: @unchecked Sendable {
    private var lock: TrackedLock<os_unfair_lock_s>

    init(_ name: StaticString) {
        lock = TrackedLock(os_unfair_lock_s(), name)
    }

    func take() {
        lock.lock()
    }

    func give() {
        lock.unlock()
    }

    func cycle(times: Int) {
        for _ in 0 ..< times {
            take()
            give()
        }
    }
}

/// An `NSLock` any thread can take, as its owner would.
private final class NamedMutex: @unchecked Sendable {
    private var lock: TrackedLock<NSLock>

    init(_ name: StaticString) {
        lock = TrackedLock(NSLock(), name)
    }

    func take() {
        lock.lock()
    }

    func give() {
        lock.unlock()
    }
}
