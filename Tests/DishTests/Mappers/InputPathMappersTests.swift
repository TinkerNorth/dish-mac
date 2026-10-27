// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// A pad's input path on its Diagnostics card and in the flight recorder:
/// the path and its one reason, a Direct pad's connection, USB ID and
/// report rate, and a line for every path decision, verdict and burst.
final class InputPathMappersTests: XCTestCase {

    private func directPath(hz: Int? = 85) -> SlotInputPath {
        var path = SlotInputPath(source: .direct, reason: .directByModel)
        path.rawReportHz = hz
        return path
    }

    func testADirectPadReadsItsPathReasonUsbIdAndRate() {
        let slot = ControllerSlot(id: "hid:057e:2019", name: "Nintendo N64 Online Controller")
        let pad = PadDiagnostics(
            slot: slot,
            wire: nil,
            backgroundInput: true,
            hardwareId: HidHardwareId(vendorId: 0x057E, productId: 0x2019),
            inputPath: directPath()
        )
        XCTAssertEqual(Array(padLines(pad).prefix(6)), [
            FactLine(key: "Connection", value: "HID reports"),
            FactLine(key: "Input path", value: "Direct"),
            FactLine(key: "Reason", value: "Dish reads this model itself"),
            FactLine(key: "Reports from the pad", value: "85 Hz"),
            FactLine(key: "USB ID", value: hardwareIdText(HidHardwareId(vendorId: 0x057E, productId: 0x2019))),
            FactLine(key: "Background input", value: "On")
        ])
    }

    func testAStandardPadNamesItsFrameworkAndItsReasonWithNoRate() {
        let path = SlotInputPath(source: .standard, reason: .macOSReads)
        XCTAssertEqual(connectionText(path), "GameController")
        XCTAssertEqual(inputPathLines(path), [
            FactLine(key: "Input path", value: "Standard"),
            FactLine(key: "Reason", value: "macOS reads it")
        ])
        XCTAssertEqual(inputPathLines(nil), [], "no facts yet, no lines")
        XCTAssertEqual(connectionText(nil), "GameController")
    }

    func testEveryReasonAndVerdictIsSpelled() {
        XCTAssertEqual(inputSourceReasonText(.directByModel), "Dish reads this model itself")
        XCTAssertEqual(inputSourceReasonText(.macOSCannotRead), "macOS does not read it, so Dish does")
        XCTAssertEqual(inputSourceReasonText(.macOSReads), "macOS reads it")
        XCTAssertEqual(inputSourceReasonText(.userPicked), "Your pick")
        XCTAssertEqual(checkVerdictText(.standardWorks), "macOS passes its input")
        XCTAssertEqual(checkVerdictText(.dishReadsIt), "Dish reads its input")
        XCTAssertEqual(checkVerdictText(.noDecoder), "no input Dish can decode")
        XCTAssertEqual(checkVerdictText(.nothingAtAll), "no input at all")
    }

    func testEveryPathEventHasItsLine() {
        let chosen = pathEvent("N64", .chosen(.direct, .directByModel), atMs: 0)
        XCTAssertEqual(eventText(chosen), "N64: input path Direct (Dish reads this model itself)")
        XCTAssertEqual(eventText(pathEvent("N64", .verdict(.nothingAtAll), atMs: 0)), "N64: check found no input at all")
        XCTAssertEqual(eventText(pathEvent("N64", .keepsDisconnecting, atMs: 0)), "N64: keeps disconnecting")
        XCTAssertEqual(
            eventText(DiagnosticsEvent(atMs: 0, kind: .padPathChosen, subject: "N64")),
            "N64",
            "a line without its note is its pad"
        )
    }
}
