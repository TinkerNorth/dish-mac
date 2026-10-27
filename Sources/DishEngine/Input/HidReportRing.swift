// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The reports "Help support this controller" records, crossing from the
// capture's thread to the main actor. The capture's callback copies each
// report into the next of a fixed set of fixed-size slots, allocated once,
// so the hot path builds nothing; the main actor drains the ring on its own
// timer. A repeat of the last report is not written again, and a full ring
// overwrites its oldest report.

import Foundation
import os

final class HidReportRing: @unchecked Sendable {
    static let slotCount = 64
    /// A report longer than this is kept to its first bytes.
    static let slotBytes = 128

    private let storage: UnsafeMutablePointer<UInt8>
    private let lengths: UnsafeMutablePointer<Int>
    /// The slot the next report goes into.
    private var head = 0
    private var count = 0
    /// A drain empties the ring but the last report still counts as last.
    private var wroteAny = false
    private var lock = os_unfair_lock_s()

    init() {
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.slotCount * Self.slotBytes)
        storage.initialize(repeating: 0, count: Self.slotCount * Self.slotBytes)
        lengths = UnsafeMutablePointer<Int>.allocate(capacity: Self.slotCount)
        lengths.initialize(repeating: 0, count: Self.slotCount)
    }

    deinit {
        storage.deallocate()
        lengths.deallocate()
    }

    /// On the capture's thread.
    func write(_ report: UnsafeBufferPointer<UInt8>) {
        let length = min(report.count, Self.slotBytes)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !repeatsLast(report, length: length) else { return }
        let slot = storage + head * Self.slotBytes
        for index in 0 ..< length {
            slot[index] = report[index]
        }
        lengths[head] = length
        head = (head + 1) % Self.slotCount
        count = min(count + 1, Self.slotCount)
        wroteAny = true
    }

    /// On the main actor: the reports held, oldest first, and the ring emptied.
    func drain() -> [[UInt8]] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let oldest = (head - count + Self.slotCount) % Self.slotCount
        let reports = (0 ..< count).map { offset in report(at: (oldest + offset) % Self.slotCount) }
        count = 0
        return reports
    }

    /// Whether the last slot written holds these bytes; the caller holds the lock.
    private func repeatsLast(_ report: UnsafeBufferPointer<UInt8>, length: Int) -> Bool {
        guard wroteAny else { return false }
        let last = (head - 1 + Self.slotCount) % Self.slotCount
        guard lengths[last] == length else { return false }
        let slot = storage + last * Self.slotBytes
        return (0 ..< length).allSatisfy { slot[$0] == report[$0] }
    }

    private func report(at index: Int) -> [UInt8] {
        Array(UnsafeBufferPointer(start: storage + index * Self.slotBytes, count: lengths[index]))
    }
}
