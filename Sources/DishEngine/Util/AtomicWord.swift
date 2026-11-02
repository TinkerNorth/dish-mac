// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishAtomics

/// A 64-bit word several threads read and write without a lock. It is a
/// view: the owner allocates the storage, keeps its address for the word's
/// whole life and frees it in its own `deinit`.
struct AtomicWord {
    let address: UnsafeMutablePointer<Int64>

    /// One word of fresh storage, holding `initial`.
    static func allocate(_ initial: Int64 = 0) -> AtomicWord {
        let address = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        address.initialize(to: initial)
        return AtomicWord(address: address)
    }

    func deallocate() {
        address.deallocate()
    }

    /// Acquire: what the storing thread wrote before its store is visible.
    func load() -> Int64 {
        dish_atomic_load(address)
    }

    func loadRelaxed() -> Int64 {
        dish_atomic_load_relaxed(address)
    }

    /// Release: everything written before it is visible to an acquiring load.
    func store(_ value: Int64) {
        dish_atomic_store(address, value)
    }

    func storeRelaxed(_ value: Int64) {
        dish_atomic_store_relaxed(address, value)
    }

    /// The value before the add.
    @discardableResult
    func fetchAdd(_ delta: Int64) -> Int64 {
        dish_atomic_fetch_add(address, delta)
    }

    @discardableResult
    func fetchAddRelaxed(_ delta: Int64) -> Int64 {
        dish_atomic_fetch_add_relaxed(address, delta)
    }

    /// The value before the store.
    func exchange(_ value: Int64) -> Int64 {
        dish_atomic_exchange(address, value)
    }

    /// Stores `desired` only while the word holds `expected`.
    func compareExchange(expected: Int64, desired: Int64) -> Bool {
        dish_atomic_compare_exchange(address, expected, desired)
    }
}

/// Orders the loads before it ahead of every load and store after it: a
/// seqlock reader's fence between its field loads and its second sequence load.
func atomicFenceAcquire() {
    dish_atomic_fence_acquire()
}

/// Orders the loads and stores before it ahead of every store after it: a
/// seqlock writer's fence between its odd sequence and its field stores.
func atomicFenceRelease() {
    dish_atomic_fence_release()
}
