// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The version-2 feedback decoders pin their byte layouts without a socket,
/// like the rumble and light-bar decoders beside them.
final class FeedbackCommandsTests: XCTestCase {

    private let leftBlock: [UInt8] = [0x21, 0xFF, 0x03, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0]
    private let rightBlock: [UInt8] = [0x25, 0x01, 0x02, 0x07, 0, 0, 0, 0, 0, 0, 0]

    func testTriggerEffectsSplitTheTwoBlocksVerbatim() throws {
        let command = try XCTUnwrap(TriggerEffectsCommand.parse(Data([3] + leftBlock + rightBlock)))
        XCTAssertEqual(command.controllerIndex, 3)
        XCTAssertEqual(command.left, leftBlock)
        XCTAssertEqual(command.right, rightBlock)
    }

    func testTriggerEffectsIgnoreATrailingExtension() throws {
        let command = try XCTUnwrap(TriggerEffectsCommand.parse(Data([0] + leftBlock + rightBlock + [0xAA, 0xBB])))
        XCTAssertEqual(command.right, rightBlock)
    }

    func testATruncatedTriggerEffectsFrameIsDropped() {
        XCTAssertNil(TriggerEffectsCommand.parse(Data([0] + leftBlock + rightBlock.dropLast())))
        XCTAssertNil(TriggerEffectsCommand.parse(Data()))
    }

    func testPlayerLedsCarryTheMask() throws {
        let command = try XCTUnwrap(PlayerLedsCommand.parse(Data([2, 0b10101])))
        XCTAssertEqual(command, PlayerLedsCommand(controllerIndex: 2, ledMask: 0b10101))
    }

    func testATruncatedPlayerLedsFrameIsDropped() {
        XCTAssertNil(PlayerLedsCommand.parse(Data([2])))
    }

    func testThePlayerNumberIsTheCountOfLitLedsCappedAtFour() {
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0).playerNumber, 0)
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0b00100).playerNumber, 1, "DualSense player 1: the centre LED")
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0b01010).playerNumber, 2)
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0b10101).playerNumber, 3)
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0b11011).playerNumber, 4)
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0b0001).playerNumber, 1, "Switch Pro player 1: the leftmost")
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0b1111).playerNumber, 4)
        XCTAssertEqual(PlayerLedsCommand(controllerIndex: 0, ledMask: 0xFF).playerNumber, 4, "more LEDs than players still reads four")
    }
}
