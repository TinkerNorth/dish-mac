// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// G6 + G8 (REST side): the protocol-1 HTTPClient against FakeSatellite —
// X-Device-Id/X-Hmac-Proof on every authed route, terminal-401 code
// carriage, 409 versioning, declarative session PUT (request shape pinned),
// reconcile GET, per-slot PUT/DELETE while live, self-unpair.

import DishCore
import XCTest
@testable import Dish

final class HTTPClientLiveTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var client: HTTPClient!
    private var pairingKey: Data!
    private var proof: String!
    private let deviceId = "device-under-test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        client = HTTPClient(pinVerifier: { _, _ in true })
        // Pre-pair without the PIN dance: plant a key, compute the proof the
        // way the manager does (DishCore).
        let keyHex = String(repeating: "1f", count: 32)
        satellite.pairingKeyHex = keyHex
        pairingKey = try XCTUnwrap(hexToBytes(keyHex))
        proof = SessionCrypto.hmacProofHex(pairingKey: pairingKey, deviceId: deviceId)
    }

    override func tearDown() {
        satellite.stop()
        super.tearDown()
    }

    private func descriptor(idx: Int = 0, type: UInt8 = 0) -> ControllerDescriptor {
        var descriptor = ControllerDescriptor()
        descriptor.ctrlIdx = idx
        descriptor.type = type
        descriptor.caps = ProtocolConstants.capAnalogTriggers | ProtocolConstants.capRumble
        descriptor.touchpadMode = .off
        return descriptor
    }

    private func putSession(
        controllers: [ControllerDescriptor] = [],
        proof: String? = nil
    ) async -> SessionResponse {
        await client.putSession(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            deviceId: deviceId,
            deviceName: "MacTest",
            hmacProof: proof ?? self.proof,
            controllers: controllers
        )
    }

    // MARK: - PUT /api/connections (G8: declarative upsert)

    func testPutSessionParsesSessionMaterial() async {
        let resp = await putSession(controllers: [descriptor()])
        XCTAssertEqual(resp.httpStatus, 200)
        XCTAssertTrue(resp.reachable)
        XCTAssertFalse(resp.unauthorized)
        XCTAssertEqual(resp.connectionId, satellite.connectionId)
        XCTAssertEqual(resp.token, satellite.lastTokenHex)
        XCTAssertEqual(resp.sessionSalt, satellite.lastSessionSaltHex)
        XCTAssertEqual(resp.sessionSalt?.count, 16, "8-byte salt as 16 hex chars")
        XCTAssertEqual(resp.protocolVersion, 1)
        XCTAssertEqual(resp.maxControllers, 16)
        XCTAssertEqual(resp.controllers.count, 1)
        XCTAssertTrue(resp.controllers[0].slotIsLive)
    }

    func testPutSessionRequestShapeIsTheContracts() async throws {
        _ = await putSession(controllers: [descriptor(idx: 0, type: 1)])
        let recorded = try XCTUnwrap(satellite.sessionPuts.last)
        // G5: protocolVersion rides every session request.
        XCTAssertEqual(recorded["protocolVersion"] as? Int, 1)
        // G6: the proof rides the body too (headers win when both present).
        XCTAssertEqual(recorded["hmacProof"] as? String, proof)
        XCTAssertEqual(recorded["deviceId"] as? String, deviceId)
        XCTAssertEqual(recorded["deviceName"] as? String, "MacTest")
        let controllers = try XCTUnwrap(recorded["controllers"] as? [[String: Any]])
        XCTAssertEqual(controllers.count, 1)
        XCTAssertEqual(controllers[0]["ctrlIdx"] as? Int, 0)
        XCTAssertEqual(controllers[0]["type"] as? Int, 1)
        XCTAssertEqual(controllers[0]["touchpadMode"] as? String, "off")
        let caps = try XCTUnwrap(controllers[0]["caps"] as? [String: Bool])
        XCTAssertEqual(caps["analogTriggers"], true)
        XCTAssertEqual(caps["rumble"], true)
        XCTAssertEqual(caps["motion"], false)
        XCTAssertEqual(caps["lightbar"], false)
        let host = try XCTUnwrap(recorded["hostFeatures"] as? [String: Any])
        XCTAssertEqual(host["mouseControl"] as? Bool, false)
    }

    func testZeroControllerSessionIsValid() async {
        let resp = await putSession(controllers: [])
        XCTAssertEqual(resp.httpStatus, 200)
        XCTAssertNotNil(resp.connectionId)
        XCTAssertTrue(resp.controllers.isEmpty)
    }

    func testRePutRotatesToken() async throws {
        let first = await putSession()
        let second = await putSession()
        XCTAssertNotEqual(
            try XCTUnwrap(first.token),
            try XCTUnwrap(second.token),
            "token must rotate per PUT (contract §Session)"
        )
        XCTAssertEqual(first.connectionId, second.connectionId, "connectionId never churns")
    }

    // MARK: - Auth (G6)

    func testBadProofDraws401WithBadProofCode() async {
        let resp = await putSession(proof: String(repeating: "00", count: 32))
        XCTAssertEqual(resp.httpStatus, 401)
        XCTAssertEqual(resp.code, "BAD_PROOF")
        XCTAssertTrue(resp.unauthorized)
    }

    func testUnpairedSatelliteDraws401NotPaired() async {
        satellite.pairingKeyHex = nil
        let resp = await putSession()
        XCTAssertEqual(resp.httpStatus, 401)
        XCTAssertEqual(resp.code, "NOT_PAIRED")
        XCTAssertTrue(resp.unauthorized)
    }

    func testHeadersAloneAuthenticateBodylessRoutes() async {
        // GET has no body — the proof can only have arrived in the
        // X-Device-Id / X-Hmac-Proof headers.
        _ = await putSession()
        let view = await client.getSession(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            connectionId: satellite.connectionId,
            deviceId: deviceId,
            hmacProof: proof
        )
        XCTAssertEqual(view.httpStatus, 200)
        XCTAssertFalse(view.unauthorized)
        XCTAssertEqual(view.connectionId, satellite.connectionId)
    }

    // MARK: - Versioning (G5)

    func testVersionRejectionDrawsTerminal409() async {
        satellite.protocolVersionReject = true
        let resp = await putSession()
        XCTAssertEqual(resp.httpStatus, 409)
        // Same construction `RestStamped.verdict` wires into the shell.
        let verdict = classifyRest(RestReply(
            status: resp.httpStatus, bodyParsed: resp.reachable, code: resp.code ?? ""
        ))
        XCTAssertEqual(verdict, .versionMismatch)
        XCTAssertEqual(resp.verdict, .versionMismatch)
    }

    // MARK: - GET /api/connections/{id} (reconcile view)

    func testReconcileViewCarriesAppliedTopologyAndEpoch() async {
        _ = await putSession(controllers: [descriptor(idx: 2, type: 1)])
        let view = await client.getSession(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            connectionId: satellite.connectionId,
            deviceId: deviceId,
            hmacProof: proof
        )
        XCTAssertEqual(view.epoch, Int(satellite.epoch))
        XCTAssertEqual(view.controllers.count, 1)
        XCTAssertEqual(view.controllers[0].ctrlIdx, 2)
        XCTAssertTrue(view.controllers[0].active)
        XCTAssertEqual(view.controllers[0].appliedType, 1)
        XCTAssertEqual(satellite.reconcileGets.count, 1)
    }

    // MARK: - Per-slot routes while live (G8)

    func testPutControllerConvergesSingleSlot() async {
        _ = await putSession(controllers: [descriptor(idx: 0, type: 0)])
        let before = satellite.epoch
        let resp = await client.putController(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            connectionId: satellite.connectionId,
            deviceId: deviceId,
            hmacProof: proof,
            descriptor: descriptor(idx: 1, type: 1)
        )
        XCTAssertEqual(resp.httpStatus, 200)
        XCTAssertEqual(resp.controller?.ctrlIdx, 1)
        XCTAssertEqual(resp.controller?.slotIsLive, true)
        XCTAssertEqual(resp.controller?.appliedType, 1)
        XCTAssertEqual(resp.epoch, Int(before) + 1, "topology change bumps the epoch")
        XCTAssertEqual(satellite.appliedControllers.count, 2)
    }

    func testDeleteControllerRemovesSlotOnly() async {
        _ = await putSession(controllers: [descriptor(idx: 0), descriptor(idx: 1)])
        let resp = await client.deleteController(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            connectionId: satellite.connectionId,
            ctrlIdx: 0,
            deviceId: deviceId,
            hmacProof: proof
        )
        XCTAssertEqual(resp.httpStatus, 200)
        XCTAssertEqual(satellite.appliedControllers.count, 1)
        XCTAssertEqual(satellite.appliedControllers.first?["ctrlIdx"] as? Int, 1)
        // Session lives on: the reconcile endpoint still answers.
        let view = await client.getSession(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            connectionId: satellite.connectionId,
            deviceId: deviceId,
            hmacProof: proof
        )
        XCTAssertEqual(view.httpStatus, 200)
    }

    // MARK: - DELETE session / DELETE pair acks

    func testDeleteSessionAck() async {
        _ = await putSession()
        let reply = await client.deleteSession(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            connectionId: satellite.connectionId,
            deviceId: deviceId,
            hmacProof: proof
        )
        XCTAssertEqual(classifyRest(reply), .ok)
    }

    func testUnpairRecordsDeviceAndDropsTrust() async {
        let reply = await client.unpair(
            ip: "127.0.0.1", port: Int(ports.rest), deviceId: deviceId, hmacProof: proof
        )
        XCTAssertEqual(classifyRest(reply), .ok)
        XCTAssertEqual(satellite.unpairCalls, [deviceId])
        XCTAssertNil(satellite.pairingKeyHex, "self-unpair drops the trust row server-side")
    }

    func testForced401CodeRidesTheAckReply() async {
        satellite.forced401Code = "NOT_PAIRED"
        let reply = await client.unpair(
            ip: "127.0.0.1", port: Int(ports.rest), deviceId: deviceId, hmacProof: proof
        )
        XCTAssertEqual(reply.status, 401)
        XCTAssertEqual(reply.code, "NOT_PAIRED")
        XCTAssertEqual(classifyRest(reply), .unauthorized)
    }

    // MARK: - Transport failure

    func testStoppedSatelliteIsUnreachable() async {
        satellite.stop()
        let resp = await putSession()
        XCTAssertEqual(resp.httpStatus, 0)
        XCTAssertFalse(resp.reachable)
        let verdict = classifyRest(RestReply(status: 0, bodyParsed: false, code: ""))
        XCTAssertEqual(verdict, .unreachable)
        XCTAssertEqual(resp.verdict, .unreachable)
    }
}
