// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// An Xbox Elite's paddles by the P1 to P4 labels on its back: the name
/// GameController files each under, the back button it also files it as,
/// and the extended-buttons bit SDL3's Apple backend (`SDL_mfijoystick.m`)
/// gives it.
private let sdlPaddles: [(name: String, backButton: String, bit: UInt32)] = [
    (GCInputXboxPaddleOne, "Back Right Button 0", ProtocolConstants.extButtonRightPaddle1),
    (GCInputXboxPaddleTwo, "Back Right Button 1", ProtocolConstants.extButtonRightPaddle2),
    (GCInputXboxPaddleThree, "Back Left Button 0", ProtocolConstants.extButtonLeftPaddle1),
    (GCInputXboxPaddleFour, "Back Left Button 1", ProtocolConstants.extButtonLeftPaddle2)
]

private let allPaddleNames = Set(sdlPaddles.map(\.name))

/// An Xbox Elite read through GameController: its paddles reach the
/// extended-buttons word under SDL's names, and only a pad whose Xbox profile
/// names all four claims the cap. GameController's own Xbox profile lists
/// `Paddle 1` to `Paddle 4` on every pad, so `EliteGamepad` is that profile
/// naming them as its paddle buttons, as an Elite's does.
@MainActor
final class GameControllerPaddlesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GCController.shouldMonitorBackgroundEvents = false
    }

    private func set(_ name: String, on pad: GCExtendedGamepad, held: Bool) throws {
        try XCTUnwrap(pad.buttons[name], "the profile lists \(name)").setValue(held ? 1 : 0)
    }

    /// The pad attached as a controller's extended profile.
    private func attached(_ pad: GCExtendedGamepad) -> (input: GameControllerInput, controller: GCController) {
        let input = GameControllerInput(connected: [])
        let controller = GCController.withExtendedGamepad()
        input.attachExtended(controller, pad: pad)
        return (input, controller)
    }

    private func nextInputPayload(_ fd: Int32) throws -> Data {
        let datagram = try XCTUnwrap(DataPlaneTestHelpers.receiveDatagram(fd: fd), "a report left for the satellite")
        return try XCTUnwrap(DataPlaneTestHelpers.openUplink(datagram)).inner.payload
    }

    func testAnElitesPaddlesAreSdlsPaddlesTheRightHandsFirst() throws {
        let elite = EliteGamepad()
        let paddles = GameControllerInput.paddleInputs(elite)
        XCTAssertEqual(GameControllerInput.padSample(elite, paddles: paddles).extButtons, 0, "no paddle held")
        for paddle in sdlPaddles {
            try set(paddle.name, on: elite, held: true)
            XCTAssertEqual(GameControllerInput.padSample(elite, paddles: paddles).extButtons, paddle.bit, "\(paddle.name) alone")
            try set(paddle.name, on: elite, held: false)
        }
    }

    /// SDL's mapping has GameController's word behind it: each paddle is also
    /// filed as the back button it is, position 0 nearest the finger's rest.
    func testGameControllerFilesEachPaddleAsTheBackButtonSdlNamesIt() throws {
        let elite = EliteGamepad()
        for paddle in sdlPaddles {
            let aliases = try XCTUnwrap(elite.buttons[paddle.name]).aliases
            XCTAssertTrue(aliases.contains(paddle.backButton), "\(paddle.name) is \(paddle.backButton)")
        }
    }

    func testOnlyAPadWhoseXboxProfileNamesAllFourPaddlesClaimsTheExtendedButtons() throws {
        let threeNamed = EliteGamepad(naming: allPaddleNames.subtracting([GCInputXboxPaddleFour]))
        let snapshot = try XCTUnwrap(GCController.withExtendedGamepad().extendedGamepad)
        let pads: [GCExtendedGamepad] = [EliteGamepad(), threeNamed, GCXboxGamepad(), snapshot]
        let claims = try pads.map { pad in try XCTUnwrap(attached(pad).input.slots.first).capabilities.hasExtendedButtons }
        XCTAssertEqual(claims, [true, false, false, false], "four paddles, three, an Xbox pad without paddles, no Xbox profile")
    }

    /// The Xbox Wireless Controller lists the paddles it does not have: its
    /// reports carry no word whatever the listed ones hold.
    func testAnXboxPadWithoutPaddlesIsReadAsBefore() throws {
        let plain = GCXboxGamepad()
        try set(GCInputXboxPaddleOne, on: plain, held: true)
        plain.buttonA.setValue(1)
        let sample = GameControllerInput.padSample(plain, paddles: GameControllerInput.paddleInputs(plain))
        XCTAssertEqual(sample.extButtons, 0)
        XCTAssertEqual(sample.pressed, [.faceA])
    }

    func testHeldPaddlesReachTheSeventeenByteFrameOfASessionSettledOnFourAndNotTheThirteenOfThree() throws {
        let (fd, port) = try XCTUnwrap(DataPlaneTestHelpers.bindLoopbackSocket())
        defer { close(fd) }
        let client = try XCTUnwrap(DataPlaneTestHelpers.makeClient(port: port))
        defer { client.closeSocket() }
        let elite = EliteGamepad()
        let (input, controller) = attached(elite)
        input.processor.route { _ in Route(sink: SatelliteClientSink(client: client, controllerIndex: 0), flags: ForwardingFlags()) }
        let call = EliteCall(pad: elite)

        XCTAssertTrue(settle(client, port: port, on: 3))
        try set(GCInputXboxPaddleOne, on: elite, held: true)
        controller.handlerQueue.sync { call.fire() }
        XCTAssertEqual(try nextInputPayload(fd).count, 13, "a session settled on 3 is sent no word")

        XCTAssertTrue(settle(client, port: port, on: 4))
        try set(GCInputXboxPaddleFour, on: elite, held: true)
        controller.handlerQueue.sync { call.fire() }
        let four = try nextInputPayload(fd)
        XCTAssertEqual(four.count, 17)
        XCTAssertEqual([UInt8](four.suffix(4)), [0x09, 0x00, 0x00, 0x00], "P1 and P4 held: right paddle 1 and left paddle 2")
    }

    private func settle(_ client: SatelliteClient, port: UInt16, on version: Int) -> Bool {
        client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: port,
            token: DataPlaneTestHelpers.testToken,
            sessionKey: DataPlaneTestHelpers.testKey,
            protocolVersion: version
        )
    }
}

/// GameController's Xbox profile naming the paddles a test asks for as its
/// paddle buttons, from the `Paddle 1` to `Paddle 4` it lists on every pad.
private final class EliteGamepad: GCXboxGamepad {
    private let named: Set<String>

    init(naming named: Set<String> = allPaddleNames) {
        self.named = named
        super.init()
    }

    override var paddleButton1: GCControllerButtonInput? {
        listed(GCInputXboxPaddleOne)
    }

    override var paddleButton2: GCControllerButtonInput? {
        listed(GCInputXboxPaddleTwo)
    }

    override var paddleButton3: GCControllerButtonInput? {
        listed(GCInputXboxPaddleThree)
    }

    override var paddleButton4: GCControllerButtonInput? {
        listed(GCInputXboxPaddleFour)
    }

    private func listed(_ name: String) -> GCControllerButtonInput? {
        named.contains(name) ? buttons[name] : nil
    }
}

/// Calls the profile's handler the way the framework does, from the queue
/// the controller was handed. The framework's objects are not `Sendable`;
/// this test owns them and touches them on one queue at a time.
private struct EliteCall: @unchecked Sendable {
    let pad: GCExtendedGamepad

    func fire() {
        pad.valueChangedHandler?(pad, pad.buttonA)
    }
}
