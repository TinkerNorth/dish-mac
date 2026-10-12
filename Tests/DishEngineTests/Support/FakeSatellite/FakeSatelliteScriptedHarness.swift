// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Shared scripted-harness boot for the FakeSatellite self- and fidelity
// suites: one booted satellite + pinned REST client + raw UDP client + a
// live session context.

import CryptoKit
import Foundation
import XCTest

let ds4Descriptor: [String: Any] = [
    "ctrlIdx": 0,
    "type": 1,
    "caps": ["rumble": true, "motion": true, "analogTriggers": true, "lightbar": true],
    "touchpadMode": "ds4"
]

/// One booted satellite + pinned REST client + raw UDP client + live session.
struct ScriptedHarness {
    let satellite: FakeSatellite
    let rest: FakeSatelliteRestScriptClient
    let udp: FakeSatelliteUdpScriptClient
    let context: FakeSatelliteScript.SessionContext

    static func boot(controllers: [[String: Any]], hostFeatures: [String: Any] = [:]) async throws -> ScriptedHarness {
        let satellite = try FakeSatellite()
        let ports = try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let deviceId = "self-test-device"
        let pairingKey = try await FakeSatelliteScript.pairOperator(rest, deviceId: deviceId)
        let context = try await FakeSatelliteScript.putSession(
            rest,
            deviceId: deviceId,
            pairingKey: pairingKey,
            controllers: controllers,
            hostFeatures: hostFeatures
        )
        return ScriptedHarness(satellite: satellite, rest: rest, udp: FakeSatelliteUdpScriptClient(port: ports.udp), context: context)
    }

    /// Seals + sends one uplink frame under the live session (overridable
    /// direction / AAD token / header token for the negative tests).
    func sendUp(
        _ opcode: UInt16,
        _ payload: Data = Data(),
        counter: UInt32,
        direction: FakeSatelliteCrypto.Direction = .clientToServer,
        aadToken: UInt32? = nil,
        token: UInt32? = nil
    ) throws {
        try udp.sendFrame(
            opcode: opcode,
            payload: payload,
            key: context.sessionKey,
            token: token ?? context.token,
            counter: counter,
            direction: direction,
            aadToken: aadToken
        )
    }

    func awaitDown() -> FakeSatelliteUdpScriptClient.DownFrame? {
        udp.awaitDownFrame(key: context.sessionKey, token: context.token)
    }

    func shutdown() {
        udp.stop()
        satellite.stop()
    }
}
