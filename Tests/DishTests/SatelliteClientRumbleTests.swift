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

    /// Build the fixed 7-byte rumble payload. Mirrors the producer side in
    /// `satellite/src/adapters/client_adapter.cpp::sendRumble`.
    private func rumblePayload(
        ctrlIdx: UInt8,
        strong: UInt16,
        weak: UInt16,
        dur: UInt16
    ) -> [UInt8] {
        [
            ctrlIdx,
            UInt8(strong >> 8), UInt8(strong & 0xFF),
            UInt8(weak >> 8), UInt8(weak & 0xFF),
            UInt8(dur >> 8), UInt8(dur & 0xFF)
        ]
    }

    func testDecodesFields() throws {
        let p = rumblePayload(ctrlIdx: 3, strong: 0xABCD, weak: 0x1234, dur: 500)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.controllerIndex, 3)
        XCTAssertEqual(rm.strongMagnitude, 0xABCD)
        XCTAssertEqual(rm.weakMagnitude, 0x1234)
        XCTAssertEqual(rm.durationMs, 500)
    }

    func testDecodesStopRequest() throws {
        let p = rumblePayload(ctrlIdx: 0, strong: 0, weak: 0, dur: 0)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.strongMagnitude, 0)
        XCTAssertEqual(rm.weakMagnitude, 0)
        XCTAssertEqual(rm.durationMs, 0)
    }

    func testDecodesMaxMagnitudes() throws {
        let p = rumblePayload(ctrlIdx: 0xFF, strong: 0xFFFF, weak: 0xFFFF, dur: 0xFFFF)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.controllerIndex, 0xFF)
        XCTAssertEqual(rm.strongMagnitude, 0xFFFF)
        XCTAssertEqual(rm.weakMagnitude, 0xFFFF)
        XCTAssertEqual(rm.durationMs, 0xFFFF)
    }

    func testRejectsTruncatedPayload() {
        // Anything shorter than 7 bytes is malformed.
        XCTAssertNil(SatelliteClient.parseRumblePayload([UInt8](repeating: 0, count: 6)))
        XCTAssertNil(SatelliteClient.parseRumblePayload([]))
    }

    func testIgnoresExtraTrailingBytes() throws {
        // Forward-compat: future protocol extensions may append fields.
        let base = rumblePayload(ctrlIdx: 2, strong: 100, weak: 50, dur: 700)
        let p = base + [UInt8](repeating: 0xAA, count: 9)
        let rm = try XCTUnwrap(SatelliteClient.parseRumblePayload(p))
        XCTAssertEqual(rm.controllerIndex, 2)
        XCTAssertEqual(rm.strongMagnitude, 100)
        XCTAssertEqual(rm.weakMagnitude, 50)
        XCTAssertEqual(rm.durationMs, 700)
    }

    func testBigEndianBoundaries() throws {
        // 0x0100 BE = 256; LE would parse as 1.
        let p = rumblePayload(ctrlIdx: 0, strong: 0x0100, weak: 0xFF00, dur: 0x00FF)
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
