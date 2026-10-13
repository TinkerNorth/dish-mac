// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The receive side of a down lane (SPEAKER_AUDIO or HAPTIC_AUDIO): a 20 ms
// playout clock pulls one decision per tick from a two-frame reorder window
// (contract §Controller audio). There are no acks and no retransmits: a
// frame that never arrives is concealed once by the decoder's PLC, a frame
// that arrives after its slot is dropped, and a window the server
// suppressed (all-zero, `seq` not advanced) is silence, never a hole.

import Foundation

/// What the playout clock does for one 20 ms window.
public enum PlayoutDecision: Equatable, Sendable {
    /// Decode and play this packet.
    case frame(Data)
    /// The window's packet is lost: let the decoder conceal it.
    case conceal
    /// Nothing to play: the server suppressed the window, or the lane is idle.
    case silence
}

/// Pure state of one lane's reorder window. The playout waits for
/// `AudioWire.reorderWindowFrames` frames before it starts, so a frame that
/// arrives one slot late still plays in order; after that a missing frame
/// is concealed as soon as a later one has arrived.
public struct AudioPlayout: Equatable, Sendable {
    /// The next sequence number to play; nil until the first frame.
    public private(set) var expected: UInt16?
    /// Frames ahead of `expected`, by sequence number.
    public private(set) var pending: [UInt16: Data] = [:]
    /// Still filling the window before the first play.
    public private(set) var priming = true
    public private(set) var played = 0
    public private(set) var concealed = 0
    public private(set) var lateDrops = 0

    public init() {}

    /// A frame arrived. Behind the playhead it is late and dropped; ahead it
    /// waits for its slot.
    public mutating func push(_ frame: AudioFrame) {
        guard let expected else {
            self.expected = frame.seq
            pending[frame.seq] = frame.opus
            return
        }
        guard Self.distance(from: expected, to: frame.seq) >= 0 else {
            lateDrops += 1
            return
        }
        pending[frame.seq] = frame.opus
    }

    /// One tick of the 20 ms clock.
    public mutating func pull() -> PlayoutDecision {
        guard let expected else { return .silence }
        if priming {
            guard pending.count >= AudioWire.reorderWindowFrames else { return .silence }
            priming = false
        }
        if let opus = pending.removeValue(forKey: expected) {
            self.expected = expected &+ 1
            played += 1
            return .frame(opus)
        }
        guard pending.keys.contains(where: { Self.distance(from: expected, to: $0) > 0 }) else { return .silence }
        self.expected = expected &+ 1
        concealed += 1
        return .conceal
    }

    /// A new session's lane starts fresh.
    public mutating func reset() {
        self = AudioPlayout()
    }

    /// Signed distance on the wrapping u16 ring: negative is behind.
    static func distance(from base: UInt16, to seq: UInt16) -> Int {
        Int(Int16(bitPattern: seq &- base))
    }
}
