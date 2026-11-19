// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The probe's word on controller audio is session state on the connection:
/// it reaches every bound pad's descriptor when the probe lands, and leaves
/// every descriptor with the session, on either way out, so the next
/// session's opening PUT promises no audio until its own probe answers.
@MainActor
final class WifiConnectionHostAudioTests: XCTestCase {

    private let audio = ProtocolConstants.capMic | ProtocolConstants.capSpeaker | ProtocolConstants.capHapticAudio
    private let granting = HostAudioVerdict(mic: true, speaker: true, hapticAudio: true)

    private func connectionWithABoundDualSense() -> WifiConnection {
        let server = DiscoveredServer(name: "Desk", ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: "desk")
        let conn = WifiConnection(id: "desk", server: server)
        let dualSense = ControllerCapabilities(hasMic: true, hasSpeaker: true, hasHapticLanes: true)
        conn.attachSlot("pad", controllerType: 0, capabilities: dualSense, family: .dualSense)
        conn.setForwardingFlags(ForwardingFlags(mic: true, speaker: true))
        return conn
    }

    private func claimed(by conn: WifiConnection) -> UInt16? {
        conn.descriptor(for: "pad").map { $0.caps & audio }
    }

    func testTheProbesWordReachesTheDescriptorAndLeavesWithTheSessionOnEitherWayOut() {
        let endings: [(String, (WifiConnection) -> Void)] = [
            ("a disconnect", { $0.markDisconnected() }),
            ("a death-path park", { $0.parkStaleAwaitingRetry() })
        ]
        for (ending, end) in endings {
            let conn = connectionWithABoundDualSense()
            conn.markConnecting()
            XCTAssertEqual(claimed(by: conn), 0, "before the probe, nothing is promised")

            conn.setHostAudio(granting)
            XCTAssertEqual(conn.hostAudio, granting)
            XCTAssertEqual(claimed(by: conn), audio, "the probe's word puts every lane on the wire")

            end(conn)
            XCTAssertEqual(conn.hostAudio, .none, ending)
            XCTAssertEqual(
                claimed(by: conn),
                0,
                "\(ending) takes the word off every descriptor, so the next opening PUT promises no audio"
            )
            XCTAssertEqual(conn.slotTable.boundSlotIds, ["pad"], "the pad stays bound for the next session")
        }
    }
}
