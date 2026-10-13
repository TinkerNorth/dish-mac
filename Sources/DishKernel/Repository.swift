// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Dumb, synchronous, thread-safe keyed storage. A repository decides
/// nothing; a `StateSource` wraps one for reactive reads.
public protocol Repository<Key, Value> {
    associatedtype Key: Hashable
    associatedtype Value

    func get(_ key: Key) -> Value?
    func all() -> [Value]
    func put(_ value: Value, for key: Key)
    func remove(_ key: Key)
    func clear()
}

/// A repository whose values carry their own key.
public protocol KeyedRepository<Key, Value>: Repository {
    func keyOf(_ value: Value) -> Key
}

public extension KeyedRepository {
    func put(_ value: Value) {
        put(value, for: keyOf(value))
    }

    func removeValue(_ value: Value) {
        remove(keyOf(value))
    }
}
