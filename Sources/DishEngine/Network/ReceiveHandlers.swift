// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// What the satellite client's receive loop calls for each message it
/// opens, swapped whole: whoever sets one handler builds a new set and posts
/// it, and the loop takes the newest before its next dispatch.
struct ReceiveHandlers {
    var rumble: ((RumbleCommand) -> Void)?
    var lightbar: ((LightbarCommand) -> Void)?
    var triggerEffects: ((TriggerEffectsCommand) -> Void)?
    var playerLeds: ((PlayerLedsCommand) -> Void)?
    var speakerAudio: ((AudioFrame) -> Void)?
    var hapticAudio: ((AudioFrame) -> Void)?
    var micLed: ((MicLedCommand) -> Void)?
    var sessionClose: ((CloseReason) -> Void)?
}

/// One set as the mailbox carries it to the receive loop.
final class ReceiveHandlersBox {
    let handlers: ReceiveHandlers

    init(_ handlers: ReceiveHandlers) {
        self.handlers = handlers
    }
}

/// The enriched heartbeat ack in one word, so the receive loop stores it and
/// the alive tick reads it with no lock: a presence bit, then each field.
extension HeartbeatAck {
    private static let present: Int64 = 1 << 48
    private static let backend: Int64 = 1 << 40

    /// Nil for the empty word, which no stored ack packs to.
    init?(packed word: Int64) {
        guard word & Self.present != 0 else { return nil }
        self.init(
            backendAvailable: word & Self.backend != 0,
            activeCount: UInt8(truncatingIfNeeded: word >> 32),
            epoch: UInt16(truncatingIfNeeded: word >> 16),
            bitmap: UInt16(truncatingIfNeeded: word)
        )
    }

    var packed: Int64 {
        Self.present | (backendAvailable ? Self.backend : 0) | Int64(activeCount) << 32 | Int64(epoch) << 16 | Int64(bitmap)
    }
}
