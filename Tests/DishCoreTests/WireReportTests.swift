// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// A pad reading becomes the XUSB report every client sends: up-positive
/// sticks, triggers on 0...255, one bit per button.
final class WireReportTests: XCTestCase {

    func testAStickPushedAllTheWayUpReadsAsFullUpOnTheWire() {
        let report = wireReport(PadSample(leftY: 1, rightY: 1))
        XCTAssertEqual(report.ly, 32767)
        XCTAssertEqual(report.ry, 32767)
    }

    func testAStickPulledAllTheWayDownReadsAsFullDownOnTheWire() {
        let report = wireReport(PadSample(leftY: -1, rightY: -1))
        XCTAssertEqual(report.ly, -32767)
        XCTAssertEqual(report.ry, -32767)
    }

    func testACentredPadIsTheReleasedReport() {
        XCTAssertEqual(wireReport(PadSample()), .released)
    }

    func testXPassesThroughAtBothRails() {
        let right = wireReport(PadSample(leftX: 1, rightX: 1))
        XCTAssertEqual(right.lx, 32767)
        XCTAssertEqual(right.rx, 32767)
        let left = wireReport(PadSample(leftX: -1, rightX: -1))
        XCTAssertEqual(left.lx, -32767)
        XCTAssertEqual(left.rx, -32767)
    }

    func testTriggersSpanTheByteAndANegativeReadingIsReleased() {
        XCTAssertEqual(wireReport(PadSample(leftTrigger: 0, rightTrigger: 0)).lt, 0)
        let pulled = wireReport(PadSample(leftTrigger: 1, rightTrigger: 1))
        XCTAssertEqual(pulled.lt, 255)
        XCTAssertEqual(pulled.rt, 255)
        let negative = wireReport(PadSample(leftTrigger: -0.4, rightTrigger: -1))
        XCTAssertEqual(negative.lt, 0)
        XCTAssertEqual(negative.rt, 0)
    }

    func testTheGuideButtonSetsTheGuideBit() {
        XCTAssertEqual(wireReport(PadSample(pressed: [.guide])).buttons, 0x0400)
    }

    func testEveryButtonSetsItsOwnBitAndTogetherTheirUnion() {
        let mapped: [(WireButton, UInt16)] = [
            (.dpadUp, 0x0001), (.dpadDown, 0x0002), (.dpadLeft, 0x0004), (.dpadRight, 0x0008),
            (.start, 0x0010), (.back, 0x0020), (.leftThumb, 0x0040), (.rightThumb, 0x0080),
            (.leftShoulder, 0x0100), (.rightShoulder, 0x0200), (.guide, 0x0400),
            (.faceA, 0x1000), (.faceB, 0x2000), (.faceX, 0x4000), (.faceY, 0x8000)
        ]
        for (button, bit) in mapped {
            XCTAssertEqual(wireReport(PadSample(pressed: [button])).buttons, bit, "\(button)")
        }
        let all = wireReport(PadSample(pressed: WireButtonWord(mapped.map(\.0))))
        XCTAssertEqual(all.buttons, 0xF7FF, "every mapped bit, and the mic-mute slot left clear")
    }

    func testAButtonWordHoldsExactlyTheButtonsInsertedIntoIt() {
        var word = WireButtonWord()
        word.insert(.faceB)
        word.insert(.dpadLeft)
        word.insert(.faceB)
        XCTAssertEqual(word.rawValue, 0x2004, "an insert ORs one bit and a repeat is a no-op")
        XCTAssertTrue(word.contains(.faceB))
        XCTAssertTrue(word.contains(.dpadLeft))
        XCTAssertFalse(word.contains(.faceA))
        XCTAssertEqual(word, [.dpadLeft, .faceB], "the literal and the inserts build the same word")
    }

    func testAnEmptyWordHoldsNoButton() {
        let word = WireButtonWord()
        XCTAssertEqual(word.rawValue, 0)
        XCTAssertTrue(WireButton.allCases.allSatisfy { !word.contains($0) })
    }

    func testAcrossTheWholeTravelTheWireKeepsTheStickYSign() {
        let samples = (0 ..< 1024).map { step in -1 + 2 * Float(step) / 1023 }
        for value in samples {
            let report = wireReport(PadSample(leftY: value, rightY: value))
            let expected = value.sign == .minus ? -1 : 1
            XCTAssertEqual(Int(report.ly.signum()), expected, "left y \(value)")
            XCTAssertEqual(Int(report.ry.signum()), expected, "right y \(value)")
        }
    }
}
