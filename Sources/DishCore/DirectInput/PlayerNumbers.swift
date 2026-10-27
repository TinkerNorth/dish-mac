// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Player 1", "Player 2": each connected pad keeps the number it got when it
// connected, a pad that leaves frees its number, and the next pad takes the
// lowest free one, so identical pads can be told apart.

import Foundation

public struct PlayerNumbers: Equatable, Sendable {
    public static let first = 1

    /// Pad id to number, for the pads connected now.
    public private(set) var numbers: [String: Int] = [:]

    public init() {}

    /// The pad's number: the one it holds, or the lowest free one.
    public mutating func connect(_ padId: String) -> Int {
        if let held = numbers[padId] { return held }
        let taken = Set(numbers.values)
        var free = PlayerNumbers.first
        while taken.contains(free) {
            free += 1
        }
        numbers[padId] = free
        return free
    }

    /// The number the pad freed, nil when it held none.
    public mutating func disconnect(_ padId: String) -> Int? {
        numbers.removeValue(forKey: padId)
    }

    public func number(for padId: String) -> Int? {
        numbers[padId]
    }
}
