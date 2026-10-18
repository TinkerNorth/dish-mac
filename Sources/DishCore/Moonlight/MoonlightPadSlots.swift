// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A Moonlight host names each virtual pad by a small controller number, and
// every CONTROLLER_MULTI carries the bitfield of the pads present: clearing a
// pad's bit while still naming it is the unplug. A host skips the arrival of
// a number it already holds, so a live number is never handed out twice.

import Foundation

public struct MoonlightPadSlots: Equatable, Sendable {
    public struct Assignment: Equatable, Sendable {
        public let slotId: String
        public let number: UInt8
    }

    public private(set) var assignments: [Assignment] = []

    public init() {}

    /// The lowest free number, or nil when the session carries its four or
    /// the slot already holds one.
    public mutating func assign(_ slotId: String) -> UInt8? {
        guard number(for: slotId) == nil else { return nil }
        let taken = Set(assignments.map(\.number))
        guard let free = (0 ..< UInt8(MoonlightProtocol.maxPads)).first(where: { !taken.contains($0) }) else { return nil }
        assignments.append(Assignment(slotId: slotId, number: free))
        return free
    }

    public func number(for slotId: String) -> UInt8? {
        assignments.first { $0.slotId == slotId }?.number
    }

    /// The slot behind a number: how a host's rumble, trigger or lamp event finds its pad.
    public func slot(for number: UInt8) -> String? {
        assignments.first { $0.number == number }?.slotId
    }

    /// The number the slot held, so the caller can send the bit-cleared frame for it.
    public mutating func release(_ slotId: String) -> UInt8? {
        guard let index = assignments.firstIndex(where: { $0.slotId == slotId }) else { return nil }
        return assignments.remove(at: index).number
    }

    public var activeMask: UInt16 {
        assignments.reduce(0) { $0 | UInt16(1) << UInt16($1.number) }
    }

    public var isEmpty: Bool {
        assignments.isEmpty
    }

    public var isFull: Bool {
        assignments.count >= MoonlightProtocol.maxPads
    }

    public var count: Int {
        assignments.count
    }
}
