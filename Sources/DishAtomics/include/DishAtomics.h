// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Lock-free loads, stores and read-modify-writes on words the engine
// allocates, for the hot paths: macOS 13 has no Swift Synchronization module.
// Each function is one C11 atomic operation (clang's builtins) on a naturally
// aligned word at a stable address; the name says its memory order when it is
// not the default: acquire for a load, release for a store, acquire-release
// for the rest.

#ifndef DISH_ATOMICS_H
#define DISH_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

static inline int64_t dish_atomic_load(const int64_t *word) {
    return __atomic_load_n(word, __ATOMIC_ACQUIRE);
}

static inline int64_t dish_atomic_load_relaxed(const int64_t *word) {
    return __atomic_load_n(word, __ATOMIC_RELAXED);
}

static inline void dish_atomic_store(int64_t *word, int64_t value) {
    __atomic_store_n(word, value, __ATOMIC_RELEASE);
}

static inline void dish_atomic_store_relaxed(int64_t *word, int64_t value) {
    __atomic_store_n(word, value, __ATOMIC_RELAXED);
}

/// Adds `delta` and returns the value before it.
static inline int64_t dish_atomic_fetch_add(int64_t *word, int64_t delta) {
    return __atomic_fetch_add(word, delta, __ATOMIC_ACQ_REL);
}

static inline int64_t dish_atomic_fetch_add_relaxed(int64_t *word, int64_t delta) {
    return __atomic_fetch_add(word, delta, __ATOMIC_RELAXED);
}

/// Stores `value` and returns the value before it.
static inline int64_t dish_atomic_exchange(int64_t *word, int64_t value) {
    return __atomic_exchange_n(word, value, __ATOMIC_ACQ_REL);
}

/// Stores `desired` only while the word holds `expected`; true when it did.
static inline bool dish_atomic_compare_exchange(int64_t *word, int64_t expected, int64_t desired) {
    return __atomic_compare_exchange_n(word, &expected, desired, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

/// The 32-bit flag a gate takes: acquire when it wins, relaxed when it loses.
static inline bool dish_atomic_compare_exchange_i32(int32_t *word, int32_t expected, int32_t desired) {
    return __atomic_compare_exchange_n(word, &expected, desired, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
}

static inline int32_t dish_atomic_load_relaxed_i32(const int32_t *word) {
    return __atomic_load_n(word, __ATOMIC_RELAXED);
}

static inline void dish_atomic_store_i32(int32_t *word, int32_t value) {
    __atomic_store_n(word, value, __ATOMIC_RELEASE);
}

/// Orders the loads before it ahead of every load and store after it.
static inline void dish_atomic_fence_acquire(void) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
}

/// Orders the loads and stores before it ahead of every store after it.
static inline void dish_atomic_fence_release(void) {
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

#pragma clang assume_nonnull end

#endif
