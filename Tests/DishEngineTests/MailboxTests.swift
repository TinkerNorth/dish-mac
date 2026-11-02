// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest
@testable import DishEngine

/// The mailbox owns each object it holds exactly once: the reader takes the
/// newest, a superseded one is released, and nothing posted is lost or kept.
final class MailboxTests: XCTestCase {

    func testTakeIsNilUntilAPostAndThenTheObjectPosted() {
        let mailbox = Mailbox<Parcel>()
        XCTAssertFalse(mailbox.hasMail)
        XCTAssertNil(mailbox.take())
        let parcel = Parcel(1)
        mailbox.post(parcel)
        XCTAssertTrue(mailbox.hasMail)
        XCTAssertTrue(mailbox.take() === parcel)
        XCTAssertFalse(mailbox.hasMail)
        XCTAssertNil(mailbox.take(), "a take empties the box")
    }

    func testAPostSaysWhetherTheBoxWasEmpty() {
        let mailbox = Mailbox<Parcel>()
        XCTAssertTrue(mailbox.post(Parcel(1)), "the first post finds the box empty")
        XCTAssertFalse(mailbox.post(Parcel(2)), "the second replaces one not yet taken")
        _ = mailbox.take()
        XCTAssertTrue(mailbox.post(Parcel(3)), "a take empties the box again")
    }

    func testANewerPostReplacesAndReleasesOneNotYetTaken() {
        let mailbox = Mailbox<Parcel>()
        weak var superseded: Parcel?
        do {
            let first = Parcel(1)
            superseded = first
            mailbox.post(first)
        }
        mailbox.post(Parcel(2))
        XCTAssertNil(superseded, "the replaced parcel is released by the post that replaced it")
        XCTAssertEqual(mailbox.take()?.value, 2)
    }

    func testTheBoxReleasesWhatItStillHoldsWhenItGoes() {
        weak var held: Parcel?
        do {
            let mailbox = Mailbox<Parcel>()
            let parcel = Parcel(3)
            held = parcel
            mailbox.post(parcel)
        }
        XCTAssertNil(held)
    }

    /// One thread posts a run of parcels while another takes: the reader
    /// sees each value at most once, in order, and ends on the last.
    func testAReaderOnAnotherThreadSeesTheNewestInOrder() {
        let mailbox = Mailbox<Parcel>()
        let posts = 20000
        let done = DispatchSemaphore(value: 0)
        let seen = LockedBox<[Int]>([])
        Thread {
            var local: [Int] = []
            while local.last != posts - 1 {
                if let parcel = mailbox.take() { local.append(parcel.value) }
            }
            seen.set(local)
            done.signal()
        }.start()
        for value in 0 ..< posts {
            mailbox.post(Parcel(value))
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        let values = seen.get()
        XCTAssertEqual(values.last, posts - 1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count, "no parcel is taken twice")
    }
}

private final class Parcel {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }
}
