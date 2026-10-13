// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The receive side of a down lane (SPEAKER_AUDIO or HAPTIC_AUDIO), rule for
// rule the window the satellite and dish-android keep: a packet in order
// plays at once, so in-order audio pays no latency; a packet behind the
// playhead is late and dropped; a packet ahead waits; a frame is declared
// lost once a held packet is two or more ahead of it, and the decoder
// conceals it; after two concealed frames in a row the window resyncs to
// the oldest held packet. There are no acks and no retransmits.

import Foundation

/// What one arrival makes the lane do, in order.
public enum PlayoutEvent: Equatable, Sendable {
    /// Decode and play this packet.
    case packet(Data)
    /// This frame was lost; conceal it. The carrier is the next packet,
    /// whose in-band FEC describes the lost one, when it is already here.
    case gap(carrier: Data?)
    /// Behind the playhead: dropped, nothing to play.
    case late
}

public struct AudioJitterWindow: Equatable, Sendable {
    /// A held packet this far ahead declares the frame before it lost.
    public static let windowFrames = 2
    /// Concealed frames in a row before the window resyncs.
    public static let maxConcealFrames = 2
    /// One arrival never floods the decoder.
    public static let maxEventsPerPush = 6

    /// The next sequence number to play; nil until the first packet.
    public private(set) var next: UInt16?
    public private(set) var held: [UInt16: Data] = [:]
    public private(set) var consecutiveGaps = 0
    public private(set) var played = 0
    public private(set) var concealed = 0
    public private(set) var lateDrops = 0

    public init() {}

    public mutating func push(_ frame: AudioFrame) -> [PlayoutEvent] {
        guard let next else {
            self.next = frame.seq &+ 1
            played += 1
            return [.packet(frame.opus)]
        }
        guard Self.distance(from: next, to: frame.seq) >= 0 else {
            lateDrops += 1
            return [.late]
        }
        held[frame.seq] = frame.opus
        return drain()
    }

    /// A new session's lane starts fresh.
    public mutating func reset() {
        self = AudioJitterWindow()
    }

    /// Everything playable now: the packet at the playhead, then the frames
    /// a far-ahead packet proves lost, then the resync when too many were.
    private mutating func drain() -> [PlayoutEvent] {
        var events: [PlayoutEvent] = []
        while events.count < Self.maxEventsPerPush, let playhead = next {
            if let opus = held.removeValue(forKey: playhead) {
                events.append(.packet(opus))
                next = playhead &+ 1
                played += 1
                consecutiveGaps = 0
                continue
            }
            guard let farthest = held.keys.map({ Self.distance(from: playhead, to: $0) }).max(),
                  farthest >= Self.windowFrames else { break }
            if consecutiveGaps >= Self.maxConcealFrames {
                next = held.keys.min { Self.distance(from: playhead, to: $0) < Self.distance(from: playhead, to: $1) }
                consecutiveGaps = 0
                continue
            }
            events.append(.gap(carrier: held[playhead &+ 1]))
            next = playhead &+ 1
            consecutiveGaps += 1
            concealed += 1
        }
        return events
    }

    /// Signed distance on the wrapping u16 ring: negative is behind.
    static func distance(from base: UInt16, to seq: UInt16) -> Int {
        Int(Int16(bitPattern: seq &- base))
    }
}
