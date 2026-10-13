// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The version-2 feedback return paths, decoded (contract §UDP messages).
// Both carry a whole state, last value wins, and the satellite replays each
// on a session's first datagram, so a repeated value is the same state.

import Foundation

/// Decoded MSG_TRIGGER_EFFECTS (0x0010): the game's DualSense trigger-effect
/// fields, one 11-byte block per trigger, forwarded verbatim. The bytes are
/// the pad firmware's vocabulary (mode byte plus ten parameters); nothing
/// here interprets them.
public struct TriggerEffectsCommand: Equatable, Sendable {
    public var controllerIndex: UInt8
    public var left: [UInt8]
    public var right: [UInt8]

    public init(controllerIndex: UInt8, left: [UInt8], right: [UInt8]) {
        self.controllerIndex = controllerIndex
        self.left = left
        self.right = right
    }

    /// Parse `ctrlIdx(1) + left(11) + right(11)`; nil on truncation. Extra
    /// trailing bytes are ignored, as a newer server may append fields.
    public static func parse(_ payload: Data) -> TriggerEffectsCommand? {
        let bytes = [UInt8](payload)
        guard bytes.count >= ProtocolConstants.triggerEffectsPayloadBytes else { return nil }
        let block = ProtocolConstants.triggerEffectBlockBytes
        return TriggerEffectsCommand(
            controllerIndex: bytes[0],
            left: Array(bytes[1 ..< 1 + block]),
            right: Array(bytes[1 + block ..< 1 + 2 * block])
        )
    }
}

/// Decoded MSG_PLAYER_LEDS (0x0011): the player-indicator bitmask, bit 0 the
/// leftmost LED (DualSense bits 0-4, Switch Pro bits 0-3).
public struct PlayerLedsCommand: Equatable, Sendable {
    public var controllerIndex: UInt8
    public var ledMask: UInt8

    public init(controllerIndex: UInt8, ledMask: UInt8) {
        self.controllerIndex = controllerIndex
        self.ledMask = ledMask
    }

    /// Parse `ctrlIdx(1) + ledMask(1)`; nil on truncation.
    public static func parse(_ payload: Data) -> PlayerLedsCommand? {
        let bytes = [UInt8](payload)
        guard bytes.count >= ProtocolConstants.playerLedsPayloadBytes else { return nil }
        return PlayerLedsCommand(controllerIndex: bytes[0], ledMask: bytes[1])
    }

    /// The player number the mask spells, for a pad whose LEDs a framework
    /// drives by player index rather than by bit. The standard patterns light
    /// one LED per player (DualSense: centre, then outward; Switch Pro: from
    /// the left), so the count of lit LEDs is the player, capped at four.
    /// Zero lit LEDs is "no player".
    public var playerNumber: Int {
        min(ledMask.nonzeroBitCount, 4)
    }
}
