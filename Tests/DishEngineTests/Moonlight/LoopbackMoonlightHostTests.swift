// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// The loopback host the bench and the lock laws measure the Moonlight path
/// against: what it reads is what the session sent, number for number, and
/// the rig carries a pad's frames to it and its events back to the pad.
@MainActor
final class LoopbackMoonlightHostTests: XCTestCase {
    private typealias Received = LoopbackMoonlightHost.Received

    func testTheRigCarriesAPadsFramesToTheHostAndTheHostsEventsToThePad() async throws {
        let host = try LoopbackMoonlightHost(capacity: 4096)
        host.start()
        defer { host.stop() }
        let rig = try await MoonlightPathRig.connect(to: host, pads: 1)
        let number = rig.padNumbers[0]
        for frame in 1 ... 50 {
            rig.inputQueues[0].async { rig.publish(pad: 0, report: GamepadReport(rx: Int16(frame))) }
        }
        host.sendRumble(controller: number, low: 0x4000, high: 0x2000)
        host.sendRgbLed(controller: number, red: 1, green: 2, blue: 3)
        var seen: [Received] = []
        let arrived = await waitUntil {
            seen += host.take()
            return frames(seen, of: number).last?.rightX == 50 && rig.feedback.rumble > 0 && rig.feedback.lightbar > 0
        }
        rig.close()
        XCTAssertTrue(arrived, "frames \(frames(seen, of: number).count), feedback \(rig.feedback)")
        XCTAssertEqual(seen.first { $0.inputType == MoonlightInputType.controllerArrival }?.controller, number, "the pad was announced")
        XCTAssertEqual(frames(seen, of: number).suffix(50).map(\.rightX), (1 ... 50).map { Int16($0) }, "each frame in order")
    }

    /// Pinned against the host's view, so a change to the session's locking
    /// shows here first: each command takes the next ENet sequence on its
    /// channel and each sealed packet the next control sequence, in the order
    /// one thread sent them.
    func testTheHostReadsEachCommandsSequencesInTheOrderTheyWereSent() async throws {
        let host = try LoopbackMoonlightHost(capacity: 256)
        host.start()
        defer { host.stop() }
        let transport = UdpControlTransport(address: "127.0.0.1", port: host.port)
        let opened = await transport.start()
        XCTAssertTrue(opened)
        let clock = AtomicInt(100_000)
        let session = MoonlightControlSession(
            rikey: host.rikey,
            connectData: 0x1234_5678,
            transport: transport,
            now: { Int64(clock.get()) },
            onEvent: { _ in },
            onClosed: {}
        )
        let connected = await session.connect()
        XCTAssertTrue(connected)
        clock.set(100_500)
        session.tick()
        sendEveryKind(on: session)
        session.stop()
        var seen: [Received] = []
        let ended = await waitUntil {
            seen += host.take()
            return seen.contains { $0.number == EnetProtocol.commandDisconnect }
        }
        XCTAssertTrue(ended, "the DISCONNECT arrived")
        XCTAssertEqual(seen.filter { $0.number != EnetProtocol.commandAcknowledge }.map(\.pinned), pinnedSequence)
    }

    /// One packet of every kind a pad sends, and a replug.
    private func sendEveryKind(on session: MoonlightControlSession) {
        let arrival = MoonlightInput.PadArrival(controller: 0, type: 2, capabilities: 0xFF, supportedButtons: 0x0010_F7FF)
        session.sendControllerArrival(arrival)
        session.sendControllerState(MoonlightInput.PadFrame(controller: 0, activeMask: 1, rightX: 1))
        session.sendControllerState(MoonlightInput.PadFrame(controller: 0, activeMask: 1, rightX: 2))
        session.sendControllerReplug(number: 0, otherPadsMask: 0, arrival: arrival)
        session.sendControllerBattery(controller: 0, state: MoonlightBatteryState.charging, percentage: 50)
        session.sendControllerMotion(controller: 0, type: MoonlightMotionType.gyro, x: 1, y: 2, z: 3)
    }

    /// What the host reads of the handshake, a tick half a second on,
    /// `sendEveryKind` and the stop: CONNECT and the ENet ping on the system
    /// channel, every sealed packet on channel 0 with its ENet and control
    /// sequence, then the unsequenced DISCONNECT.
    private var pinnedSequence: [Received] {
        [
            Received(command: 0x82, channel: 0xFF, reliableSequence: 1),
            Received(command: 0x85, channel: 0xFF, reliableSequence: 2),
            sealed(1, seq: 0, type: MoonlightProtocol.packetPeriodicPing),
            input(2, seq: 1, MoonlightInputType.controllerArrival),
            input(3, seq: 2, MoonlightInputType.controllerMulti, rightX: 1),
            input(4, seq: 3, MoonlightInputType.controllerMulti, rightX: 2),
            input(5, seq: 4, MoonlightInputType.controllerMulti),
            input(6, seq: 5, MoonlightInputType.controllerArrival),
            input(7, seq: 6, MoonlightInputType.controllerBattery),
            input(8, seq: 7, MoonlightInputType.controllerMotion),
            sealed(9, seq: 8, type: MoonlightProtocol.packetTermination),
            Received(command: 0x44, channel: 0xFF, reliableSequence: 0)
        ]
    }

    /// Polls on the main actor until `predicate` holds or five seconds pass.
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0 ..< 250 where !predicate() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}

private extension LoopbackMoonlightHost.Received {
    /// Everything the host read but the moment it read it.
    var pinned: Self {
        var pinned = self
        pinned.ns = 0
        return pinned
    }
}

/// A reliable command on channel 0 carrying one sealed control packet.
private func sealed(_ reliable: UInt16, seq: UInt32, type: UInt16) -> LoopbackMoonlightHost.Received {
    LoopbackMoonlightHost.Received(command: 0x86, channel: 0, reliableSequence: reliable, seq: seq, type: type)
}

/// A reliable command on channel 0 carrying one input packet for pad 0.
private func input(_ reliable: UInt16, seq: UInt32, _ inputType: UInt32, rightX: Int16 = 0) -> LoopbackMoonlightHost.Received {
    LoopbackMoonlightHost.Received(
        command: 0x86,
        channel: 0,
        reliableSequence: reliable,
        seq: seq,
        type: MoonlightProtocol.packetInputData,
        inputType: inputType,
        controller: 0,
        rightX: rightX
    )
}

private func frames(_ seen: [LoopbackMoonlightHost.Received], of number: UInt16) -> [LoopbackMoonlightHost.Received] {
    seen.filter { $0.inputType == MoonlightInputType.controllerMulti && $0.controller == number }
}
