// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Harness fidelity vs the real satellite: pins the places where the harness
// used to be MORE LENIENT than `routes_client.cpp` / `session_service.cpp` /
// `receiver.cpp` — leniency here lets client regressions stay green.

import Foundation
import XCTest

final class FakeSatelliteFidelitySelfTests: XCTestCase {

    func testRePutRetiresTheReplacedTokenFromTheDataPlane() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [])
        defer { harness.shutdown() }
        let old = harness.context
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1)
        XCTAssertTrue(harness.satellite.awaitHeartbeats(atLeast: 1))

        _ = try await FakeSatelliteScript.putSession(
            harness.rest,
            deviceId: old.deviceId,
            pairingKey: old.pairingKey,
            controllers: []
        )
        // The replaced token must stop decrypting — the real satellite
        // extracts the session row on re-PUT.
        try harness.udp.sendFrame(
            opcode: FakeSatelliteOpcode.heartbeat,
            payload: Data(),
            key: old.sessionKey,
            token: old.token,
            counter: 2
        )
        XCTAssertTrue(harness.satellite.awaitUnknownTokenDrops(atLeast: 1))
        XCTAssertEqual(harness.satellite.heartbeatCount, 1, "the old token must not keep acking")
    }

    func testForeignDeviceIdWithSelfConsistentProofIsNotPaired() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        // The meddler knows the pairing key and mints a valid proof for its
        // OWN deviceId — the real satellite has no row for it: 401 NOT_PAIRED.
        let proof = FakeSatelliteCrypto.hmacProofHex(
            pairingKey: harness.context.pairingKey,
            deviceId: "meddler"
        )
        let headers = ["X-Device-Id": "meddler", "X-Hmac-Proof": proof]
        let get = try await harness.rest.request("GET", "/api/connections/conn_fake01", headers: headers)
        XCTAssertEqual(get.status, 401)
        XCTAssertEqual(get.string("code"), "NOT_PAIRED")
        let del = try await harness.rest.request("DELETE", "/api/connections/conn_fake01/controllers/0", headers: headers)
        XCTAssertEqual(del.status, 401)
        XCTAssertEqual(harness.satellite.appliedControllers.count, 1, "the slot must survive the foreign call")
    }

    func testInnerFrameLengthOverrunIsDroppedAndTrailingBytesAreSliced() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [])
        defer { harness.shutdown() }
        let context = harness.context
        // Declared msgLen overruns the plaintext → drop (receiver.cpp:152).
        var overrun = FakeSatelliteCrypto.be16(FakeSatelliteOpcode.heartbeat)
        overrun.append(FakeSatelliteCrypto.be16(64)) // claims 64 payload bytes; has 0
        let overrunBox = try FakeSatelliteCrypto.seal(
            overrun,
            key: context.sessionKey,
            direction: .clientToServer,
            counter: 1,
            token: context.token
        )
        harness.udp.send(FakeSatelliteCrypto.tokenBE(context.token) + FakeSatelliteCrypto.be32(1) + overrunBox)
        XCTAssertTrue(harness.satellite.awaitAuthFailDrops(atLeast: 1))
        XCTAssertEqual(harness.satellite.heartbeatCount, 0)

        // Trailing bytes beyond msgLen are sliced off, not delivered.
        let report = Data((0 ..< 12).map { UInt8($0) })
        var padded = FakeSatelliteCrypto.be16(FakeSatelliteOpcode.input)
        padded.append(FakeSatelliteCrypto.be16(13))
        padded.append(Data([0]) + report + Data([0xEE, 0xEE])) // 2 trailing junk bytes
        let paddedBox = try FakeSatelliteCrypto.seal(
            padded,
            key: context.sessionKey,
            direction: .clientToServer,
            counter: 2,
            token: context.token
        )
        harness.udp.send(FakeSatelliteCrypto.tokenBE(context.token) + FakeSatelliteCrypto.be32(2) + paddedBox)
        let input = try XCTUnwrap(harness.satellite.awaitFrame(opcode: FakeSatelliteOpcode.input))
        XCTAssertEqual(input.payload.count, 13, "payload must be sliced to msgLen")
        XCTAssertEqual(input.detail, .input(ctrlIdx: 0, report: report))
    }

    func testSessionPutAuthPrecedesVersionCheck() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        _ = try await FakeSatelliteScript.pairOperator(rest, deviceId: "d7")
        // Bad proof AND bad version: the real route auths first → 401.
        let reply = try await rest.request(
            "PUT",
            "/api/connections",
            json: ["deviceId": "d7", "protocolVersion": 2],
            headers: ["X-Device-Id": "d7", "X-Hmac-Proof": String(repeating: "0", count: 64)]
        )
        XCTAssertEqual(reply.status, 401, "auth precedes the version check (upsertConnectionRoute)")
    }

    func testClosedSessionRoutesAnswer404() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        let auth = ["X-Device-Id": harness.context.deviceId, "X-Hmac-Proof": harness.context.proofHex]
        let closed = try await harness.rest.request("DELETE", "/api/connections/conn_fake01", headers: auth)
        XCTAssertEqual(closed.status, 200)

        let get = try await harness.rest.request("GET", "/api/connections/conn_fake01", headers: auth)
        XCTAssertEqual(get.status, 404, "reconcile GET must 404 after close")
        let slotPut = try await harness.rest.request(
            "PUT",
            "/api/connections/conn_fake01/controllers/0",
            json: ["type": 0],
            headers: auth
        )
        XCTAssertEqual(slotPut.status, 404, "slot PUT must 404 after close")
        let reDelete = try await harness.rest.request("DELETE", "/api/connections/conn_fake01", headers: auth)
        XCTAssertEqual(reDelete.status, 404, "double close must 404, not 200")
    }

    func testCapsOnlyConvergeDoesNotBumpEpoch() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        let auth = ["X-Device-Id": harness.context.deviceId, "X-Hmac-Proof": harness.context.proofHex]
        let epochBefore = harness.satellite.epoch

        // Same slot, same type, rumble flipped: in-place converge, no bump
        // (session_service applyDescriptorLocked same-family arm).
        var capsOnly = ds4Descriptor
        capsOnly["caps"] = ["rumble": false, "motion": true, "analogTriggers": true, "lightbar": true]
        let slotPut = try await harness.rest.request(
            "PUT",
            "/api/connections/conn_fake01/controllers/0",
            json: capsOnly,
            headers: auth
        )
        XCTAssertEqual(slotPut.status, 200)
        XCTAssertEqual(harness.satellite.epoch, epochBefore, "caps-only converge must not move the epoch")

        // Caps-only session re-PUT: same rule.
        _ = try await FakeSatelliteScript.putSession(
            harness.rest,
            deviceId: harness.context.deviceId,
            pairingKey: harness.context.pairingKey,
            controllers: [capsOnly]
        )
        XCTAssertEqual(harness.satellite.epoch, epochBefore, "caps-only re-PUT must not move the epoch")

        // A TYPE change is a replug → epoch moves.
        var retyped = capsOnly
        retyped["type"] = 0
        let replug = try await harness.rest.request(
            "PUT",
            "/api/connections/conn_fake01/controllers/0",
            json: retyped,
            headers: auth
        )
        XCTAssertEqual(replug.status, 200)
        XCTAssertEqual(harness.satellite.epoch, epochBefore &+ 1, "a type change bumps the epoch")
    }

    func testEmptyPinProbeAnswers200NotOk() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        // The real pairRoute's terminal arm is 200 {"ok":false,...} — a 400
        // would classify as a different failure client-side.
        let probe = try await rest.request("POST", "/api/pair", json: ["deviceId": "d8", "deviceName": "n"])
        XCTAssertEqual(probe.status, 200)
        XCTAssertEqual(probe.bool("ok"), false)
        let wrongPin = try await rest.request("POST", "/api/pair", json: ["deviceId": "d8", "pin": "0000"])
        XCTAssertEqual(wrongPin.status, 200)
        XCTAssertEqual(wrongPin.bool("ok"), false)
    }

    func testShuttingDownKnobAnswers503BeforeAuth() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        satellite.shuttingDown = true
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        // No auth at all: the g_appRunning guard answers before clientAuthed.
        let reply = try await rest.request("PUT", "/api/connections", json: ["deviceId": "d9"])
        XCTAssertEqual(reply.status, 503)
        XCTAssertEqual(reply.string("error"), "shutting down")
    }
}
