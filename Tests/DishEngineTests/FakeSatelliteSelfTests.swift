// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Self-tests proving the FakeSatellite harness implements protocol 1
// (satellite/docs/contract.md) correctly BEFORE wave-3 drives the real app
// against it: pinned cross-repo crypto vectors, a raw scripted client
// exercising pair → PUT → encrypted input → enriched ack → close-notify,
// replay/AAD rejection, and the 409 / terminal-401 knobs.

import CryptoKit
import Foundation
import Security
import XCTest

// WARNING (cross-repo contract): the hex vectors below are pinned to the
// SAME bytes asserted by satellite tests/test_session_crypto.cpp,
// dish-linux tests/test_session_crypto.cpp,
// dish-windows test_session_crypto.cpp and dish-android SessionCryptoTest.
// Any drift on any end is a cross-end protocol break, not a refactor.
private let interopPairingBytes = Data((1 ... 32).map { UInt8($0) })
private let pinnedProofHexForDevice1 = "05a035a10c55fdfe254c9df5df55a614ac128b123a5de225ea33b41f1d4eedde"
private let pinnedHkdfOutputHex = "946f704cf07e2dde5e9995a70d3d103753b4687a7ed9656bc6481b06065a8584"
private let interopSalt = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18])

func le16(_ value: Int16) -> Data {
    let bits = UInt16(bitPattern: value)
    return Data([UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)])
}

func le32(_ value: UInt32) -> Data {
    Data([
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24)
    ])
}

// MARK: - Pinned interop vectors + AEAD binding (independent implementation)

final class FakeSatelliteCryptoSelfTests: XCTestCase {

    func testHmacProofMatchesPinnedInteropVector() {
        let proof = FakeSatelliteCrypto.hmacProofHex(pairingKey: interopPairingBytes, deviceId: "device-1")
        XCTAssertEqual(proof, pinnedProofHexForDevice1)
        XCTAssertEqual(proof.count, 64)
    }

    func testHmacProofIsDeviceAndKeyBoundAndVerifies() {
        let proof = FakeSatelliteCrypto.hmacProofHex(pairingKey: interopPairingBytes, deviceId: "device-1")
        XCTAssertNotEqual(FakeSatelliteCrypto.hmacProofHex(pairingKey: interopPairingBytes, deviceId: "device-2"), proof)
        var otherKey = interopPairingBytes
        otherKey[0] = 0x7F
        XCTAssertNotEqual(FakeSatelliteCrypto.hmacProofHex(pairingKey: otherKey, deviceId: "device-1"), proof)
        XCTAssertTrue(FakeSatelliteCrypto.verifyHmacProof(pairingKey: interopPairingBytes, deviceId: "device-1", proofHex: proof))
        XCTAssertFalse(FakeSatelliteCrypto.verifyHmacProof(pairingKey: interopPairingBytes, deviceId: "device-2", proofHex: proof))
        XCTAssertFalse(FakeSatelliteCrypto.verifyHmacProof(pairingKey: otherKey, deviceId: "device-1", proofHex: proof))
        XCTAssertFalse(FakeSatelliteCrypto.verifyHmacProof(pairingKey: interopPairingBytes, deviceId: "device-1", proofHex: ""))
        XCTAssertFalse(FakeSatelliteCrypto.verifyHmacProof(pairingKey: interopPairingBytes, deviceId: "device-1", proofHex: "abc"))
        var tampered = proof
        tampered = "z" + tampered.dropFirst()
        XCTAssertFalse(FakeSatelliteCrypto.verifyHmacProof(pairingKey: interopPairingBytes, deviceId: "device-1", proofHex: tampered))
    }

    func testSessionKeyMatchesPinnedHkdfInteropVector() {
        let key = FakeSatelliteCrypto.deriveSessionKey(pairingKey: interopPairingBytes, salt: interopSalt, token: 0x1234_5678)
        XCTAssertEqual(FakeSatelliteCrypto.hexString(FakeSatelliteCrypto.keyData(key)), pinnedHkdfOutputHex)
    }

    func testSessionKeyDeterministicNeverRawAndInputBound() {
        let one = FakeSatelliteCrypto.deriveSessionKey(pairingKey: interopPairingBytes, salt: interopSalt, token: 0x1234_5678)
        let two = FakeSatelliteCrypto.deriveSessionKey(pairingKey: interopPairingBytes, salt: interopSalt, token: 0x1234_5678)
        XCTAssertEqual(FakeSatelliteCrypto.keyData(one), FakeSatelliteCrypto.keyData(two))
        XCTAssertNotEqual(FakeSatelliteCrypto.keyData(one), interopPairingBytes)
        let otherToken = FakeSatelliteCrypto.deriveSessionKey(pairingKey: interopPairingBytes, salt: interopSalt, token: 0x1234_5679)
        XCTAssertNotEqual(FakeSatelliteCrypto.keyData(one), FakeSatelliteCrypto.keyData(otherToken))
        var salt2 = interopSalt
        salt2[salt2.count - 1] = 0x19
        let otherSalt = FakeSatelliteCrypto.deriveSessionKey(pairingKey: interopPairingBytes, salt: salt2, token: 0x1234_5678)
        XCTAssertNotEqual(FakeSatelliteCrypto.keyData(one), FakeSatelliteCrypto.keyData(otherSalt))
    }

    func testAeadBindsDirectionCounterAndToken() throws {
        var keyBytes = Data(count: 32)
        keyBytes.replaceSubrange(0 ..< 3, with: [9, 9, 9])
        let key = SymmetricKey(data: keyBytes)
        let inner = FakeSatelliteCrypto.encodeInner(msgType: 0x0002, payload: Data())
        let box = try FakeSatelliteCrypto.seal(inner, key: key, direction: .clientToServer, counter: 1, token: 0xAABB_CCDD)
        let opened = try FakeSatelliteCrypto.open(box, key: key, direction: .clientToServer, counter: 1, token: 0xAABB_CCDD)
        XCTAssertEqual(opened, inner)
        XCTAssertNil(try? FakeSatelliteCrypto.open(box, key: key, direction: .serverToClient, counter: 1, token: 0xAABB_CCDD))
        XCTAssertNil(try? FakeSatelliteCrypto.open(box, key: key, direction: .clientToServer, counter: 2, token: 0xAABB_CCDD))
        XCTAssertNil(try? FakeSatelliteCrypto.open(box, key: key, direction: .clientToServer, counter: 1, token: 0xAABB_CCDE))
        // Same key + counter, opposite direction → different bytes (no nonce reuse).
        let downBox = try FakeSatelliteCrypto.seal(inner, key: key, direction: .serverToClient, counter: 1, token: 0xAABB_CCDD)
        XCTAssertEqual(downBox.count, box.count)
        XCTAssertNotEqual(downBox, box)
    }

    func testClientFramingFirstCounterIsOneNotZero() throws {
        // Mirrors dish-linux "send framing" pin: first send uses counter 1;
        // counter 0 (the pre-protocol-1 off-by-one) must not authenticate.
        var keyBytes = Data(count: 32)
        keyBytes[0] = 0xAB
        let key = SymmetricKey(data: keyBytes)
        let token: UInt32 = 0x0007_A1B2
        let inner = FakeSatelliteCrypto.encodeInner(msgType: 0x0002, payload: Data())
        let box = try FakeSatelliteCrypto.seal(inner, key: key, direction: .clientToServer, counter: 1, token: token)
        XCTAssertEqual(try FakeSatelliteCrypto.open(box, key: key, direction: .clientToServer, counter: 1, token: token), inner)
        XCTAssertNil(try? FakeSatelliteCrypto.open(box, key: key, direction: .clientToServer, counter: 0, token: token))
        XCTAssertNil(try? FakeSatelliteCrypto.open(box, key: key, direction: .serverToClient, counter: 1, token: token))
    }

    func testDatagramFramingRoundTripsThroughSlices() throws {
        // parseDatagram hands back a SLICE (non-zero startIndex); opening it
        // must still work — guards the classic Data-slice indexing pitfall.
        let key = FakeSatelliteCrypto.deriveSessionKey(pairingKey: interopPairingBytes, salt: interopSalt, token: 7)
        let payload = Data([0x01, 0x02, 0x03])
        let inner = FakeSatelliteCrypto.encodeInner(msgType: 0x000B, payload: payload)
        let datagram = try FakeSatelliteCrypto.sealDatagram(inner: inner, key: key, direction: .clientToServer, counter: 3, token: 7)
        let header = try XCTUnwrap(FakeSatelliteCrypto.parseDatagram(datagram))
        XCTAssertEqual(header.token, 7)
        XCTAssertEqual(header.counter, 3)
        let reopened = try FakeSatelliteCrypto.open(header.box, key: key, direction: .clientToServer, counter: 3, token: 7)
        let parsed = try XCTUnwrap(FakeSatelliteCrypto.parseInner(reopened))
        XCTAssertEqual(parsed.msgType, 0x000B)
        XCTAssertEqual(Data(parsed.payload), payload)
    }
}

// MARK: - Runtime-minted identities

final class FakeSatelliteIdentitySelfTests: XCTestCase {

    func testMintedIdentitiesAreDistinctAndWellFormed() throws {
        let one = try FakeSatelliteCertificateMint.mint(commonName: "self-test-a")
        let two = try FakeSatelliteCertificateMint.mint(commonName: "self-test-b")
        XCTAssertNotEqual(one.certificateDER, two.certificateDER)
        XCTAssertNotEqual(one.fingerprintSHA256Hex, two.fingerprintSHA256Hex)
        XCTAssertEqual(one.fingerprintSHA256Hex.count, 64)
        XCTAssertNotNil(SecCertificateCopyKey(one.certificate)) // SPKI parses
        XCTAssertNotNil(SecCertificateCopyKey(two.certificate))
    }

    func testImposterCertificateRejectedByPinnedClient() async throws {
        let real = try FakeSatellite()
        defer { real.stop() }
        let ports = try real.start()
        let imposterTemplate = try FakeSatellite() // never started; provides a different pin
        XCTAssertNotEqual(real.certificateDER, imposterTemplate.certificateDER)
        try XCTSkipIf(real.transport != .https, "TLS identity unavailable headlessly; DER inequality asserted above")
        // Client pinned to the WRONG cert must abort the handshake — the
        // exact TOFU-mismatch behavior wave 3 asserts against the real app.
        let pinnedToImposter = FakeSatelliteRestScriptClient(port: ports.rest, https: true, pinnedDER: imposterTemplate.certificateDER)
        do {
            _ = try await pinnedToImposter.request("GET", "/api/catalog")
            XCTFail("expected the pinned client to reject the presented certificate")
        } catch {
            XCTAssertGreaterThanOrEqual(pinnedToImposter.certificateMismatches, 1)
        }
        // Correctly pinned client works against the same listener.
        let pinnedCorrectly = FakeSatelliteRestScriptClient(satellite: real)
        let reply = try await pinnedCorrectly.request("GET", "/api/server/capabilities")
        XCTAssertEqual(reply.status, 200)
    }
}

// MARK: - REST control plane

final class FakeSatelliteRestSelfTests: XCTestCase {

    func testOperatorPinPairing() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let wrong = try await rest.request("POST", "/api/pair", json: ["deviceId": "d1", "deviceName": "n", "pin": "9999"])
        XCTAssertEqual(wrong.status, 200)
        XCTAssertEqual(wrong.bool("ok"), false)
        XCTAssertNil(satellite.pairingKeyHex)
        let paired = try await rest.request(
            "POST",
            "/api/pair",
            json: ["deviceId": "d1", "deviceName": "n", "pin": "1234", "protocolVersion": 1]
        )
        XCTAssertEqual(paired.status, 200)
        XCTAssertEqual(paired.bool("ok"), true)
        XCTAssertEqual(paired.int("protocolVersion"), 1)
        XCTAssertEqual(paired.string("sharedKey")?.count, 64)
        XCTAssertEqual(satellite.pairingKeyHex, paired.string("sharedKey"))
        XCTAssertEqual(satellite.pairedDeviceId, "d1")
        // No PIN at all: the real route's terminal arm is 200 {"ok":false}.
        let missing = try await rest.request("POST", "/api/pair", json: ["deviceId": "d1", "deviceName": "n"])
        XCTAssertEqual(missing.status, 200)
        XCTAssertEqual(missing.bool("ok"), false)
    }

    func testClientPinApprovalHandsKeyExactlyOnce() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let pending = try await rest.request("POST", "/api/pair", json: ["deviceId": "d2", "deviceName": "n", "clientPin": "5678"])
        XCTAssertEqual(pending.bool("pending"), true)
        XCTAssertEqual(satellite.lastClientPin, "5678")
        let poll1 = try await rest.request("GET", "/api/pair/status?deviceId=d2")
        XCTAssertEqual(poll1.string("status"), "pending")
        satellite.approveClientPin()
        let poll2 = try await rest.request("GET", "/api/pair/status?deviceId=d2")
        XCTAssertEqual(poll2.string("status"), "approved")
        let keyHex = try XCTUnwrap(poll2.string("sharedKey"))
        XCTAssertEqual(keyHex, satellite.pairingKeyHex)
        let poll3 = try await rest.request("GET", "/api/pair/status?deviceId=d2")
        XCTAssertEqual(poll3.string("status"), "none") // staged key is single-use
        // The handed key authenticates a session PUT.
        let key = try XCTUnwrap(FakeSatelliteCrypto.hexToData(keyHex))
        let context = try await FakeSatelliteScript.putSession(rest, deviceId: "d2", pairingKey: key, controllers: [])
        XCTAssertEqual(context.connectionId, "conn_fake01")
        // Deny path is sticky until the next clientPin request.
        _ = try await rest.request("POST", "/api/pair", json: ["deviceId": "d2", "deviceName": "n", "clientPin": "0001"])
        satellite.denyClientPin()
        let denied = try await rest.request("GET", "/api/pair/status?deviceId=d2")
        XCTAssertEqual(denied.string("status"), "denied")
    }

    func testProtocolVersionNegotiation() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let rejected = try await rest.request(
            "POST",
            "/api/pair",
            json: ["deviceId": "d3", "deviceName": "n", "pin": "1234", "protocolVersion": 2]
        )
        XCTAssertEqual(rejected.status, 409)
        XCTAssertEqual(rejected.int("supported"), 1)
        // Absent protocolVersion means 1 (contract §Versioning).
        let absent = try await rest.request("POST", "/api/pair", json: ["deviceId": "d3", "deviceName": "n", "pin": "1234"])
        XCTAssertEqual(absent.status, 200)
        // Knob: force 409 even for a well-formed v1 session PUT.
        satellite.protocolVersionReject = true
        let key = try XCTUnwrap(try FakeSatelliteCrypto.hexToData(XCTUnwrap(satellite.pairingKeyHex)))
        do {
            _ = try await FakeSatelliteScript.putSession(rest, deviceId: "d3", pairingKey: key, controllers: [])
            XCTFail("expected 409 from the protocolVersionReject knob")
        } catch {}
        satellite.protocolVersionReject = false
        _ = try await FakeSatelliteScript.putSession(rest, deviceId: "d3", pairingKey: key, controllers: [])
    }

    func testTerminal401Codes() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        // Unpaired satellite → NOT_PAIRED.
        let notPaired = try await rest.request("PUT", "/api/connections", json: ["deviceId": "d4", "hmacProof": "00"])
        XCTAssertEqual(notPaired.status, 401)
        XCTAssertEqual(notPaired.string("code"), "NOT_PAIRED")
        // Wrong proof against a paired satellite → BAD_PROOF.
        _ = try await FakeSatelliteScript.pairOperator(rest, deviceId: "d4")
        let badProof = try await rest.request(
            "PUT",
            "/api/connections",
            json: ["deviceId": "d4", "controllers": []],
            headers: ["X-Device-Id": "d4", "X-Hmac-Proof": String(repeating: "0", count: 64)]
        )
        XCTAssertEqual(badProof.status, 401)
        XCTAssertEqual(badProof.string("code"), "BAD_PROOF")
        // Knob: forced terminal 401 with a chosen code despite a valid proof.
        satellite.forced401Code = "NOT_PAIRED"
        let key = try XCTUnwrap(try FakeSatelliteCrypto.hexToData(XCTUnwrap(satellite.pairingKeyHex)))
        let proof = FakeSatelliteCrypto.hmacProofHex(pairingKey: key, deviceId: "d4")
        let forced = try await rest.request(
            "PUT",
            "/api/connections",
            json: ["deviceId": "d4", "controllers": []],
            headers: ["X-Device-Id": "d4", "X-Hmac-Proof": proof]
        )
        XCTAssertEqual(forced.status, 401)
        XCTAssertEqual(forced.string("code"), "NOT_PAIRED")
        satellite.forced401Code = nil
        _ = try await FakeSatelliteScript.putSession(rest, deviceId: "d4", pairingKey: key, controllers: [])
    }

    func testCatalogETagAndCapabilities() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let catalog = try await rest.request("GET", "/api/catalog")
        XCTAssertEqual(catalog.status, 200)
        XCTAssertEqual(catalog.headers["etag"], "\"1.6.0+en\"")
        XCTAssertEqual(catalog.string("locale"), "en")
        XCTAssertEqual(catalog.array("controllerTypes")?.count, 4)
        let cached = try await rest.request("GET", "/api/catalog", headers: ["If-None-Match": "\"1.6.0+en\""])
        XCTAssertEqual(cached.status, 304)
        XCTAssertTrue(cached.body.isEmpty)
        XCTAssertEqual(satellite.catalogRequests, 2)
        let caps = try await rest.request("GET", "/api/server/capabilities")
        XCTAssertEqual(caps.status, 200)
        XCTAssertEqual(caps.int("protocolVersion"), 1)
        XCTAssertEqual((caps.dict("backend"))?["id"] as? String, "fake")
    }

    func testSessionLifecycleEpochAndSlots() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        try satellite.start()
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let key = try await FakeSatelliteScript.pairOperator(rest, deviceId: "d5")
        let first = try await FakeSatelliteScript.putSession(rest, deviceId: "d5", pairingKey: key, controllers: [ds4Descriptor])
        XCTAssertEqual(first.epoch, 2) // [] → [slot 0] is an applied change
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        // Identical re-PUT: token rotates, epoch does not.
        let second = try await FakeSatelliteScript.putSession(rest, deviceId: "d5", pairingKey: key, controllers: [ds4Descriptor])
        XCTAssertEqual(second.epoch, 2)
        XCTAssertNotEqual(second.token, first.token)
        XCTAssertEqual(satellite.lastTokenHex, String(format: "%08x", second.token))
        // Reconcile GET reflects applied state; epoch override wins.
        let auth = ["X-Device-Id": "d5", "X-Hmac-Proof": second.proofHex]
        let view = try await rest.request("GET", "/api/connections/conn_fake01", headers: auth)
        XCTAssertEqual(view.status, 200)
        XCTAssertEqual(view.int("epoch"), 2)
        let slot = try XCTUnwrap(view.array("controllers")?.first)
        XCTAssertEqual(slot["active"] as? Bool, true)
        XCTAssertEqual(slot["appliedType"] as? Int, 1)
        XCTAssertEqual(slot["touchpadMode"] as? String, "ds4")
        satellite.ackEpochOverride = 55
        let drifted = try await rest.request("GET", "/api/connections/conn_fake01", headers: auth)
        XCTAssertEqual(drifted.int("epoch"), 55)
        satellite.ackEpochOverride = nil
        XCTAssertEqual(satellite.reconcileGets.count, 2)
        let foreign = try await rest.request("GET", "/api/connections/other", headers: auth)
        XCTAssertEqual(foreign.status, 404) // not your session → 404 (contract)
        // Per-slot converge: PUT adds slot 1, DELETE removes it (epoch moves).
        let slotPut = try await rest.request(
            "PUT",
            "/api/connections/conn_fake01/controllers/1",
            json: ["type": 0, "caps": ["rumble": true]],
            headers: auth
        )
        XCTAssertEqual(slotPut.status, 200)
        XCTAssertEqual(slotPut.int("epoch"), 3)
        XCTAssertEqual((slotPut.dict("controller"))?["result"] as? String, "ok")
        XCTAssertEqual(satellite.appliedControllers.count, 2)
        let slotDelete = try await rest.request("DELETE", "/api/connections/conn_fake01/controllers/1", headers: auth)
        XCTAssertEqual(slotDelete.int("epoch"), 4)
        XCTAssertEqual(satellite.appliedControllers.count, 1)
        // Graceful session close clears the session; applied pads unplug.
        let closed = try await rest.request("DELETE", "/api/connections/conn_fake01", headers: auth)
        XCTAssertEqual(closed.status, 200)
        XCTAssertNil(satellite.lastTokenHex)
        XCTAssertEqual(satellite.epoch, 5)
    }

    func testSelfUnpairClearsTrust() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [])
        defer { harness.shutdown() }
        let context = harness.context
        // Establish the UDP reply path so the unpaired notify can be sent.
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1)
        let ack = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(ack.opcode, FakeSatelliteOpcode.heartbeatAck)
        let reply = try await harness.rest.request(
            "DELETE",
            "/api/pair",
            headers: ["X-Device-Id": context.deviceId, "X-Hmac-Proof": context.proofHex]
        )
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.bool("ok"), true)
        // Close-notify (reason unpaired) rides the old session key.
        let close = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(close.opcode, FakeSatelliteOpcode.sessionClose)
        XCTAssertEqual(close.payload, Data([FakeSatelliteCloseReason.unpaired.rawValue]))
        XCTAssertNil(harness.satellite.pairingKeyHex)
        XCTAssertEqual(harness.satellite.unpairCalls, [context.deviceId])
        // The key is gone: the next PUT is terminal NOT_PAIRED.
        let after = try await harness.rest.request(
            "PUT",
            "/api/connections",
            json: ["deviceId": context.deviceId],
            headers: ["X-Device-Id": context.deviceId, "X-Hmac-Proof": context.proofHex]
        )
        XCTAssertEqual(after.status, 401)
        XCTAssertEqual(after.string("code"), "NOT_PAIRED")
    }
}
