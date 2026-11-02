// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishBench

/// The Direct pad's frames carry their sequence on the right stick, through
/// the production Switch decoder and back, without moving its calibration.
final class SwitchSequenceTests: XCTestCase {

    func testEveryByteReadsBackAsItself() {
        XCTAssertTrue(SwitchSequence().isLossless)
    }

    func testASequenceSurvivesTheSwitchDecoder() {
        let table = SwitchSequence()
        var calibration = SwitchStickCalibration()
        for sequence: UInt16 in [0, 1, 255, 256, 0x1234, 0xFF00, 0xFFFF] {
            let stick = SwitchSequence.rawStick(sequence)
            let report = switchProReport(rightX: stick.x, rightY: stick.y)
            let reading = report.withUnsafeBufferPointer { decodeSwitchReport($0, kind: .pro, calibration: &calibration) }
            XCTAssertEqual(table.sequence(rx: reading?.report.rx ?? 0, ry: reading?.report.ry ?? 0), sequence)
        }
        XCTAssertEqual(calibration, SwitchStickCalibration(), "the throw never taught the decoder a longer reach")
    }

    func testAStickTheBenchNeverSentNamesNoFrame() {
        XCTAssertNil(SwitchSequence().sequence(rx: 0, ry: 0))
    }
}

/// A full Switch Pro 0x30 report: left stick centred, the right stick raw.
private func switchProReport(rightX: UInt16, rightY: UInt16) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 49)
    bytes[0] = 0x30
    bytes[2] = 0x91
    bytes[7] = 0x08
    bytes[8] = 0x80
    bytes[9] = UInt8(truncatingIfNeeded: rightX)
    bytes[10] = UInt8(truncatingIfNeeded: rightX >> 8) & 0x0F | UInt8(truncatingIfNeeded: rightY << 4)
    bytes[11] = UInt8(truncatingIfNeeded: rightY >> 4)
    return bytes
}
