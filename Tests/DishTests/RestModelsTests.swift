// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pins the protocol-1 REST DTO JSON shapes to contract §Session /
// §Controller / §Pairing — the same bodies the FakeSatellite harness and the
// real satellite emit. Field names must never drift: they are the wire.

import DishCore
import XCTest
@testable import Dish

final class RestModelsTests: XCTestCase {

    // MARK: - SessionResponse

    func testSessionResponseParsesFullPutBody() throws {
        let body = """
        {
          "connectionId": "conn_ab12cd34",
          "token": "0007a1b2",
          "sessionSalt": "0102030405060708",
          "epoch": 3,
          "maxControllers": 16,
          "protocolVersion": 1,
          "controllers": [
            { "ctrlIdx": 0, "result": "ok", "appliedType": 1,
              "motion": { "sinkSupportedForType": true, "backendOk": true } }
          ],
          "hostFeatures": { "mouseControl": { "granted": true } }
        }
        """
        let resp = try JSONDecoder().decode(SessionResponse.self, from: Data(body.utf8))
        XCTAssertEqual(resp.connectionId, "conn_ab12cd34")
        XCTAssertEqual(resp.token, "0007a1b2")
        XCTAssertEqual(resp.sessionSalt, "0102030405060708")
        XCTAssertEqual(resp.epoch, 3)
        XCTAssertEqual(resp.maxControllers, 16)
        XCTAssertEqual(resp.protocolVersion, 1)
        XCTAssertEqual(resp.controllers.count, 1)
        XCTAssertEqual(resp.controllers[0].ctrlIdx, 0)
        XCTAssertTrue(resp.controllers[0].ok)
        XCTAssertTrue(resp.controllers[0].slotIsLive)
        XCTAssertEqual(resp.controllers[0].appliedType, 1)
        XCTAssertTrue(resp.controllers[0].motionSinkSupportedForType)
        XCTAssertTrue(resp.controllers[0].motionBackendOk)
        XCTAssertTrue(resp.mouseControl.granted)
        XCTAssertNil(resp.code)
        XCTAssertFalse(resp.unauthorized)
    }

    func testSessionResponseParses401ErrorBody() throws {
        let body = #"{"error":"unauthorized","code":"NOT_PAIRED"}"#
        let resp = try JSONDecoder().decode(SessionResponse.self, from: Data(body.utf8))
        XCTAssertNil(resp.connectionId)
        XCTAssertNil(resp.token)
        XCTAssertNil(resp.sessionSalt)
        XCTAssertEqual(resp.error, "unauthorized")
        XCTAssertEqual(resp.code, "NOT_PAIRED")
        XCTAssertTrue(resp.unauthorized)
    }

    func testBadProofIsAlsoTerminal() throws {
        let resp = try JSONDecoder().decode(
            SessionResponse.self,
            from: Data(#"{"error":"unauthorized","code":"BAD_PROOF"}"#.utf8)
        )
        XCTAssertTrue(resp.unauthorized)
        // Any other code is NOT the terminal auth pair.
        let other = try JSONDecoder().decode(
            SessionResponse.self,
            from: Data(#"{"error":"x","code":"SOMETHING_ELSE"}"#.utf8)
        )
        XCTAssertFalse(other.unauthorized)
    }

    func testReplugFailedSlotStaysLiveWithPreviousType() throws {
        // contract §Session: on replugFailed the previous pad is left
        // untouched and appliedType reports the type still in force.
        let body = """
        {"controllers":[{"ctrlIdx":0,"result":"replugFailed","appliedType":0}]}
        """
        let resp = try JSONDecoder().decode(SessionResponse.self, from: Data(body.utf8))
        XCTAssertFalse(resp.controllers[0].ok)
        XCTAssertTrue(resp.controllers[0].slotIsLive)
        XCTAssertEqual(resp.controllers[0].appliedType, 0)
    }

    func testUnknownApplyResultIsNotLive() throws {
        let resp = try JSONDecoder().decode(
            SessionResponse.self,
            from: Data(#"{"controllers":[{"ctrlIdx":0,"result":"futureCode"}]}"#.utf8)
        )
        XCTAssertFalse(resp.controllers[0].slotIsLive)
    }

    func testHostFeatureDenialCarriesReason() throws {
        let resp = try JSONDecoder().decode(
            SessionResponse.self,
            from: Data(
                #"{"hostFeatures":{"mouseControl":{"granted":false,"reason":"notSupported"}}}"#.utf8
            )
        )
        XCTAssertFalse(resp.mouseControl.granted)
        XCTAssertEqual(resp.mouseControl.reason, "notSupported")
    }

    // MARK: - SessionViewDto (reconcile GET)

    func testSessionViewParsesAppliedControllers() throws {
        let body = """
        {
          "connectionId": "conn_1",
          "epoch": 9,
          "controllers": [
            { "ctrlIdx": 2, "active": true, "appliedType": 1, "touchpadMode": "ds4" }
          ],
          "hostFeatures": { "mouseControl": { "granted": false, "reason": "denied" } }
        }
        """
        let view = try JSONDecoder().decode(SessionViewDto.self, from: Data(body.utf8))
        XCTAssertEqual(view.connectionId, "conn_1")
        XCTAssertEqual(view.epoch, 9)
        XCTAssertEqual(view.controllers.count, 1)
        XCTAssertEqual(view.controllers[0].ctrlIdx, 2)
        XCTAssertTrue(view.controllers[0].active)
        XCTAssertEqual(view.controllers[0].appliedType, 1)
        XCTAssertEqual(view.controllers[0].touchpadMode, "ds4")
        XCTAssertFalse(view.mouseControl.granted)
        XCTAssertFalse(view.unauthorized)
    }

    // MARK: - ControllerPutResponse

    func testControllerPutResponseParsesResultAndEpoch() throws {
        let body = """
        {"epoch":4,"controller":{"ctrlIdx":1,"result":"noSlots"}}
        """
        let resp = try JSONDecoder().decode(ControllerPutResponse.self, from: Data(body.utf8))
        XCTAssertEqual(resp.epoch, 4)
        XCTAssertEqual(resp.controller?.ctrlIdx, 1)
        XCTAssertEqual(resp.controller?.slotIsLive, false)
        XCTAssertFalse(resp.unauthorized)
    }

    // MARK: - PairStatusResponse

    func testPairStatusResponseShapes() throws {
        let approved = try JSONDecoder().decode(
            PairStatusResponse.self,
            from: Data(#"{"ok":true,"status":"approved","sharedKey":"aa"}"#.utf8)
        )
        XCTAssertTrue(approved.ok)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(approved.sharedKey, "aa")

        let pending = try JSONDecoder().decode(
            PairStatusResponse.self,
            from: Data(#"{"ok":false,"status":"pending"}"#.utf8)
        )
        XCTAssertEqual(pending.status, "pending")
        XCTAssertNil(pending.sharedKey)
    }

    // MARK: - ControllerDescriptor request shape

    func testControllerDescriptorEncodesContractShape() throws {
        var descriptor = ControllerDescriptor()
        descriptor.ctrlIdx = 0
        descriptor.type = 1
        descriptor.caps = ProtocolConstants.capRumble
            | ProtocolConstants.capMotion
            | ProtocolConstants.capAnalogTriggers
        descriptor.touchpadMode = .off

        let data = try JSONEncoder().encode(descriptor)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["ctrlIdx"] as? Int, 0)
        XCTAssertEqual(obj["type"] as? Int, 1)
        XCTAssertEqual(obj["touchpadMode"] as? String, "off")
        let caps = try XCTUnwrap(obj["caps"] as? [String: Bool])
        XCTAssertEqual(caps["rumble"], true)
        XCTAssertEqual(caps["motion"], true)
        XCTAssertEqual(caps["analogTriggers"], true)
        XCTAssertEqual(caps["lightbar"], false)
    }
}
