// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest
@testable import DishEngine

/// A tracked lock is the primitive it wraps: it serialises its holders
/// whichever primitive it holds, and a role's queue is a plain serial queue.
final class TrackedLockTests: XCTestCase {

    func testATrackedUnfairLockSerialisesItsHolders() {
        let counter = LockedCounter(TrackedLock(os_unfair_lock_s(), "test.unfairCounter"))
        hammer(counter)
        XCTAssertEqual(counter.value, Self.threads * Self.rounds)
    }

    func testATrackedNSLockSerialisesItsHolders() {
        let counter = LockedCounter(TrackedLock(NSLock(), "test.nsLockCounter"))
        hammer(counter)
        XCTAssertEqual(counter.value, Self.threads * Self.rounds)
    }

    func testARoleQueueKeepsItsLabelAndQuality() {
        let queue = ThreadRole.input.queue(label: "test.roleQueue", qos: .userInteractive)
        XCTAssertEqual(queue.label, "test.roleQueue")
        XCTAssertEqual(queue.qos, .userInteractive)
    }

    func testEveryRoleHasItsOwnName() {
        let names = ThreadRole.allCases.map(\.name)
        XCTAssertEqual(Set(names).count, ThreadRole.allCases.count)
        XCTAssertEqual(ThreadRole.hidReader.name, "HidReader")
    }

    private static let threads = 4
    private static let rounds = 5000

    private func hammer(_ counter: some Incrementing) {
        let group = DispatchGroup()
        for _ in 0 ..< Self.threads {
            group.enter()
            Thread {
                for _ in 0 ..< Self.rounds {
                    counter.increment()
                }
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }
}

private protocol Incrementing: Sendable {
    func increment()
}

/// A count several threads bump through one tracked lock.
private final class LockedCounter<Primitive: LockPrimitive>: Incrementing, @unchecked Sendable {
    private var lock: TrackedLock<Primitive>
    private var count = 0

    init(_ lock: TrackedLock<Primitive>) {
        self.lock = lock
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
