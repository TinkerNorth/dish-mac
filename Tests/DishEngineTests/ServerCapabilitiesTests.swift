// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// The capabilities probe's DTO reads the contract's dynamic document and
/// treats every absent block as "not there".
final class ServerCapabilitiesTests: XCTestCase {

    func testTheFakeFixtureParses() throws {
        let probe = try JSONDecoder().decode(ServerCapabilitiesDTO.self, from: Data(FakeSatelliteRest.capabilitiesJSON.utf8))
        XCTAssertEqual(probe.protocolVersion, 3)
        XCTAssertEqual(probe.serverVersion, "1.6.0")
        XCTAssertEqual(probe.maxControllers, 16)
        XCTAssertTrue(probe.backendAvailable)
        XCTAssertTrue(probe.motionAvailable)
        XCTAssertTrue(probe.host.catalog.supported)
        XCTAssertTrue(probe.host.mouseControl.available)
        XCTAssertFalse(probe.host.keyboardControl.supported)
        XCTAssertFalse(probe.controllerAudio.enabled)
        XCTAssertFalse(probe.reachable, "the stamp is the gateway's, not the body's")
    }

    func testAnOlderServerOmitsBlocksAndEachReadsAbsent() throws {
        let probe = try JSONDecoder().decode(ServerCapabilitiesDTO.self, from: Data(#"{"serverVersion":"1.2.0"}"#.utf8))
        XCTAssertEqual(probe.protocolVersion, 1, "absent means a pre-versioning satellite")
        XCTAssertFalse(probe.backendAvailable)
        XCTAssertFalse(probe.motionAvailable)
        XCTAssertFalse(probe.host.catalog.supported, "no host block means an older satellite")
        XCTAssertEqual(probe.controllerAudio, ServerControllerAudio())
    }

    func testAnEmptyBodyIsTheDefaultDocument() throws {
        let probe = try JSONDecoder().decode(ServerCapabilitiesDTO.self, from: Data("{}".utf8))
        XCTAssertEqual(probe, ServerCapabilitiesDTO())
    }
}
