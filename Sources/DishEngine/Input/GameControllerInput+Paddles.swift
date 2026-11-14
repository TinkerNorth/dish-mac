// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController

/// The extended-buttons bit each of an Xbox Elite's paddles is, by the P1 to
/// P4 labels on its back, as SDL3's Apple backend (`SDL_mfijoystick.m`)
/// maps them.
private let paddleButtons: [(KeyPath<GCXboxGamepad, GCControllerButtonInput?>, UInt32)] = [
    (\.paddleButton1, ProtocolConstants.extButtonRightPaddle1),
    (\.paddleButton2, ProtocolConstants.extButtonRightPaddle2),
    (\.paddleButton3, ProtocolConstants.extButtonLeftPaddle1),
    (\.paddleButton4, ProtocolConstants.extButtonLeftPaddle2)
]

/// An Xbox Elite's back paddles, read with the pad's report into the
/// protocol 4 extended-buttons word.
extension GameControllerInput {

    /// A pad's paddles and their bits, found once at attach so a report walks
    /// a fixed array and builds nothing.
    typealias PaddleInputs = [(input: GCControllerButtonInput, bit: UInt32)]

    /// The paddles an Xbox profile names, all four or none.
    static func paddleInputs(_ pad: GCExtendedGamepad) -> PaddleInputs {
        guard let xbox = pad as? GCXboxGamepad else { return [] }
        let named = paddleButtons.compactMap { paddle, bit in xbox[keyPath: paddle].map { (input: $0, bit: bit) } }
        return named.count == paddleButtons.count ? named : []
    }

    /// The paddles held, as the extended-buttons word.
    nonisolated static func heldPaddles(_ paddles: PaddleInputs) -> UInt32 {
        paddles.reduce(0) { word, paddle in paddle.input.isPressed ? word | paddle.bit : word }
    }
}
