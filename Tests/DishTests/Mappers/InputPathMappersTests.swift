// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// A pad's input path on its Diagnostics card and in the flight recorder
/// (the path and its one reason, a Direct pad's connection, USB ID and
/// report rate, its player number, a pad that keeps dropping, and a line
/// for every path decision, verdict and burst), and on its card: the
/// prompt until the path is proven, the "Not responding?" check with its
/// countdown, finding and action, and the picker where both paths work.
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
        XCTAssertEqual(inputSourceReasonText(.dishCouldNotRead), "Dish couldn’t read it directly, so macOS reads it")
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

    func testDiagnosticsNamesThePlayerAndAPadThatKeepsDropping() {
        var path = SlotInputPath(source: .standard, reason: .dishCouldNotRead)
        path.playerNumber = 2
        path.keepsDisconnecting = true
        XCTAssertEqual(inputPathLines(path), [
            FactLine(key: "Input path", value: "Standard"),
            FactLine(key: "Reason", value: "Dish couldn’t read it directly, so macOS reads it"),
            FactLine(key: "Player", value: "2"),
            FactLine(key: "Disconnects", value: "Keeps disconnecting")
        ])
    }

    // MARK: - The card

    func testAnUnprovenPadAsksForAButtonAndOffersTheCheck() throws {
        var path = directPath()
        path.playerNumber = 1
        let state = try XCTUnwrap(padPathState(path))
        XCTAssertEqual(state.title, "Input path")
        XCTAssertEqual(state.path, "Direct")
        XCTAssertEqual(state.reason, "Dish reads this model itself")
        XCTAssertEqual(state.player, "Player 1")
        XCTAssertEqual(state.prompt, "Press any button on this controller")
        XCTAssertEqual(state.check, PadCheckState(link: "Not responding?", countdown: nil, verdict: nil, action: nil))
        XCTAssertNil(state.picker, "no other path on offer, no control")
        XCTAssertNil(padPathState(nil), "no facts yet, nothing drawn")
    }

    func testTheFirstRealChangeTakesThePromptAway() {
        var path = directPath()
        path.proven = true
        XCTAssertNil(padPathState(path)?.prompt)
    }

    func testARunningCheckAsksForAWithItsCountdownInsteadOfThePrompt() {
        var path = directPath()
        path.check = .running(secondsLeft: 4)
        let state = padPathState(path)
        XCTAssertNil(state?.prompt)
        XCTAssertEqual(state?.check, PadCheckState(link: nil, countdown: "Press A now · 4 s", verdict: nil, action: nil))
    }

    func testEveryFindingHasItsLineAndItsOneAction() {
        let cases: [(CheckVerdict, CheckOffer, String, CheckActionState?)] = [
            (.standardWorks, .none, "It responds through macOS", nil),
            (.dishReadsIt, .useDirect, "It responds when Dish reads it directly", .useDirect("Use Direct")),
            (
                .noDecoder,
                .helpSupport,
                "Nothing arrived, and Dish can’t read this controller yet",
                .helpSupport("Help support this controller")
            ),
            (
                .nothingAtAll,
                .connectionHint,
                "Nothing arrived from this controller",
                .hint("Check the cable or the Bluetooth connection, then try again")
            )
        ]
        for (verdict, offer, line, action) in cases {
            let check = padCheckState(.concluded(verdict, offer: offer))
            XCTAssertEqual(check, PadCheckState(link: "Not responding?", countdown: nil, verdict: line, action: action), line)
        }
    }

    func testThePickerShowsBothPathsOnlyWhereTheOtherIsOnOffer() throws {
        var path = directPath()
        path.picks = [.standard]
        let picker = try XCTUnwrap(padPathState(path)?.picker)
        XCTAssertEqual(picker.title, "Input path")
        XCTAssertEqual(picker.options.map(\.label), ["Standard", "Direct"])
        XCTAssertEqual(picker.selected, .direct)
    }

    func testHelpingSupportAControllerOpensDiagnosticsForNow() {
        XCTAssertEqual(helpSupportPage(forSlot: "gc:pad"), .diagnostics)
    }

    func testAHomeNodeReadsThePlayerPathAndReasonOnOneLine() throws {
        var path = directPath()
        path.playerNumber = 3
        XCTAssertEqual(try padNodePathLine(XCTUnwrap(padPathState(path))), "Player 3 · Direct · Dish reads this model itself")
        path.playerNumber = nil
        XCTAssertEqual(try padNodePathLine(XCTUnwrap(padPathState(path))), "Direct · Dish reads this model itself")
    }
}
