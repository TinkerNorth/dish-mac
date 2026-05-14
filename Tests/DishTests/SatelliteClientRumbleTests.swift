// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for `SatelliteClient.parseRumblePayload` — the pure decoder for
/// the satellite → dish `MSG_RUMBLE` payload. The full I/O path (decrypt +
/// dispatch on the receive queue) is intentionally out of scope here; it
/// would require driving the receive loop with a fake socket. The decoder
/// is the only part of the rumble pipeline with real branching logic worth
/// pinning down in unit tests, and it's exposed publicly + statically for
/// exactly that reason.
final class SatelliteClientRumbleTests: XCTestCase {

    /// Build the mandatory 8-byte rumble payload (no lightbar). Mirrors the
    /// producer side in `satellite/src/adapters/client_adapter.cpp::sendRumble`.
    private func mandatoryPayload(
        ctrlIdx: UInt8,
        strong: UInt16,
        weak: UInt16,
        dur: UInt16
    ) -> [UInt8] {
        return [
            ctrlIdx,
            UInt8(strong >> 8), UInt8(strong & 0xFF),
            UInt8(weak >> 8), UInt8(weak & 0xFF),
            UInt8(dur >> 8), UInt8(dur & 0xFF),
            0x00, // flags
        ]
    }

    /// 11-byte payload with the lightbar flag set + RGB tail.
    private func lightbarPayload(
        ctrlIdx: UInt8,
        strong: UInt16,
        weak: UInt16,
        dur: UInt16,
        r: UInt8, g: UInt8, b: UInt8
    ) -> [UInt8] {
        var p = mandatoryPayload(ctrlIdx: ctrlIdx, strong: strong, weak: weak, dur: dur)
        p[7] = 0x01
        p.append(contentsOf: [r, g, b])
        return p
    }

    func testDecodesMandatoryFields() throws {
        let p = mandatoryPayload(ctrlIdx: 3, strong: 0xABCD, weak: 0x1234, dur: 500)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.controllerIndex, 3)
        XCTAssertEqual(rm.strongMagnitude, 0xABCD)
        XCTAssertEqual(rm.weakMagnitude, 0x1234)
        XCTAssertEqual(rm.durationMs, 500)
        XCTAssertFalse(rm.hasLightbar)
        XCTAssertEqual(rm.lightbarR, 0)
        XCTAssertEqual(rm.lightbarG, 0)
        XCTAssertEqual(rm.lightbarB, 0)
    }

    func testDecodesStopRequest() throws {
        let p = mandatoryPayload(ctrlIdx: 0, strong: 0, weak: 0, dur: 0)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.strongMagnitude, 0)
        XCTAssertEqual(rm.weakMagnitude, 0)
        XCTAssertEqual(rm.durationMs, 0)
    }

    func testDecodesMaxMagnitudes() throws {
        let p = mandatoryPayload(ctrlIdx: 0xFF, strong: 0xFFFF, weak: 0xFFFF, dur: 0xFFFF)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.controllerIndex, 0xFF)
        XCTAssertEqual(rm.strongMagnitude, 0xFFFF)
        XCTAssertEqual(rm.weakMagnitude, 0xFFFF)
        XCTAssertEqual(rm.durationMs, 0xFFFF)
    }

    func testDecodesLightbarTail() throws {
        let p = lightbarPayload(
            ctrlIdx: 1, strong: 0x0100, weak: 0x0080, dur: 250,
            r: 0xDE, g: 0xAD, b: 0xBE
        )
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertTrue(rm.hasLightbar)
        XCTAssertEqual(rm.lightbarR, 0xDE)
        XCTAssertEqual(rm.lightbarG, 0xAD)
        XCTAssertEqual(rm.lightbarB, 0xBE)
    }

    func testRejectsTruncatedMandatory() {
        // Anything shorter than 8 bytes is malformed.
        XCTAssertNil(SatelliteClient.parseRumblePayload([UInt8](repeating: 0, count: 7)))
        XCTAssertNil(SatelliteClient.parseRumblePayload([]))
    }

    func testRejectsLightbarFlagWithTruncatedTail() {
        // Flag set but only 8 bytes total — RGB needs 3 more.
        var p = mandatoryPayload(ctrlIdx: 0, strong: 0, weak: 0, dur: 0)
        p[7] = 0x01
        XCTAssertNil(SatelliteClient.parseRumblePayload(p))
        // 10 bytes is also short.
        var p10 = [UInt8](repeating: 0, count: 10)
        p10[7] = 0x01
        XCTAssertNil(SatelliteClient.parseRumblePayload(p10))
    }

    func testIgnoresExtraTrailingBytes() throws {
        // Forward-compat: future protocol extensions may append fields.
        let base = lightbarPayload(
            ctrlIdx: 2, strong: 100, weak: 50, dur: 700, r: 1, g: 2, b: 3
        )
        let p = base + [UInt8](repeating: 0xAA, count: 9)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.controllerIndex, 2)
        XCTAssertEqual(rm.strongMagnitude, 100)
        XCTAssertEqual(rm.lightbarR, 1)
        XCTAssertEqual(rm.lightbarG, 2)
        XCTAssertEqual(rm.lightbarB, 3)
    }

    func testReservedFlagBitsDoNotEnableLightbar() throws {
        // Only bit 0 currently means anything. Higher bits should NOT toggle
        // lightbar parsing — that's reserved for future use.
        var p = mandatoryPayload(ctrlIdx: 0, strong: 0, weak: 0, dur: 0)
        p[7] = 0x02 // bit 1 set, bit 0 clear
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertFalse(rm.hasLightbar)
    }

    func testBigEndianBoundaries() throws {
        // 0x0100 BE = 256; LE would parse as 1.
        let p = mandatoryPayload(ctrlIdx: 0, strong: 0x0100, weak: 0xFF00, dur: 0x00FF)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.strongMagnitude, 0x0100)
        XCTAssertEqual(rm.weakMagnitude, 0xFF00)
        XCTAssertEqual(rm.durationMs, 0x00FF)
    }

    func testProtocolConstant() {
        // Pinned to wire value 0x0009 to match satellite/src/core/types.h.
        XCTAssertEqual(SatelliteClient.msgRumble, 0x0009)
    }
}
