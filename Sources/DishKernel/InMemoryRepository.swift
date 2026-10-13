// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A lock-guarded dictionary behind the `Repository` contract. The storage
/// tests and headless runs use it; production repositories wrap a durable
/// store the same way.
public final class InMemoryRepository<Key: Hashable, Value>: Repository, @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func all() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.values)
    }

    public func put(_ value: Value, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
