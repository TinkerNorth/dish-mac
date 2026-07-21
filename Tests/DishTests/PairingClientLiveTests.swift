// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// G5 + G16: the async PairingClient against the in-process FakeSatellite —
// operator-PIN path A, client-PIN path B (status poll, single-use staged
// key), protocolVersion carriage with terminal 409, and the
// unreachable-vs-auth split.

import XCTest
@testable import Dish

final class PairingClientLiveTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var client: PairingClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite(operatorPin: "4321")
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        // Trust-everything verifier: TOFU has its own suite; these tests pin
        // the REST semantics.
        client = PairingClient(pinVerifier: { _, _ in true })
    }

    override func tearDown() {
        satellite.stop()
        super.tearDown()
    }

    private func pair(pin: String, clientPin: String = "") async -> PairResponse {
        await client.pair(
            ip: "127.0.0.1",
            port: Int(ports.rest),
            deviceId: "device-under-test",
            deviceName: "MacTest",
            pin: pin,
            clientPin: clientPin
        )
    }

    // MARK: - Path A (operator PIN)

    func testPathACorrectPinHandsBackKey() async {
        let response = await pair(pin: "4321")
        guard case let .success(sharedKeyHex) = PairingClient.classify(response) else {
            return XCTFail("expected success, got \(PairingClient.classify(response))")
        }
        XCTAssertEqual(sharedKeyHex, satellite.pairingKeyHex)
        XCTAssertEqual(satellite.pairedDeviceId, "device-under-test")
        XCTAssertEqual(satellite.pairedDeviceName, "MacTest")
        XCTAssertEqual(response.httpStatus, 200)
    }

    func testPathAWrongPinIsAuthRequired() async {
        let response = await pair(pin: "0000")
        XCTAssertEqual(PairingClient.classify(response), .authRequired)
        XCTAssertNil(satellite.pairingKeyHex, "a refused PIN must not mint a key")
    }

    func testEmptyPinsAreRejectedNotShortCircuited() async {
        // Protocol-1 deleted the "already paired → hand back the key"
        // short-circuit; a bare POST must NOT return a key.
        satellite.pairingKeyHex = String(repeating: "aa", count: 32)
        let response = await pair(pin: "")
        XCTAssertEqual(PairingClient.classify(response), .authRequired)
    }

    // MARK: - G5: protocolVersion + 409

    func testVersionRejectionClassifiesAsVersionMismatch() async {
        satellite.protocolVersionReject = true
        let response = await pair(pin: "4321")
        XCTAssertEqual(response.httpStatus, 409)
        XCTAssertEqual(PairingClient.classify(response), .versionMismatch)
    }

    // MARK: - Path B (client PIN + status poll)

    func testPathBSubmitPollApproveHandsKeyExactlyOnce() async {
        let submitted = await pair(pin: "", clientPin: "7788")
        XCTAssertEqual(PairingClient.classify(submitted), .pendingApproval)
        XCTAssertEqual(satellite.lastClientPin, "7788")

        // Operator hasn't acted yet: poll reports pending.
        let pending = await client.pairStatus(
            ip: "127.0.0.1", port: Int(ports.rest), deviceId: "device-under-test"
        )
        XCTAssertEqual(PairingClient.classifyStatus(pending), .pending)

        satellite.approveClientPin()

        let approved = await client.pairStatus(
            ip: "127.0.0.1", port: Int(ports.rest), deviceId: "device-under-test"
        )
        guard case let .approved(sharedKeyHex) = PairingClient.classifyStatus(approved) else {
            return XCTFail("expected approved, got \(PairingClient.classifyStatus(approved))")
        }
        XCTAssertEqual(sharedKeyHex, satellite.pairingKeyHex)

        // The staged key is single-use (contract §Pairing Read): a replayed
        // poll must not hand it back again.
        let replay = await client.pairStatus(
            ip: "127.0.0.1", port: Int(ports.rest), deviceId: "device-under-test"
        )
        XCTAssertEqual(PairingClient.classifyStatus(replay), .declined)
    }

    func testPathBDenyStopsThePoll() async {
        _ = await pair(pin: "", clientPin: "9911")
        satellite.denyClientPin()
        let status = await client.pairStatus(
            ip: "127.0.0.1", port: Int(ports.rest), deviceId: "device-under-test"
        )
        XCTAssertEqual(PairingClient.classifyStatus(status), .declined)
    }

    // MARK: - Transport failure

    func testClosedPortIsUnreachable() async {
        satellite.stop()
        let response = await pair(pin: "4321")
        XCTAssertFalse(response.reachable)
        if case .unreachable = PairingClient.classify(response) {
            // expected
        } else {
            XCTFail("expected unreachable, got \(PairingClient.classify(response))")
        }
    }
}
