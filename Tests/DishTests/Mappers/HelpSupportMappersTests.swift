// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// "Help support this controller": looking for the device, one step at a
/// time with its count of reports seen, then the report with Copy and the
/// issue link. Nothing is sent from here.
final class HelpSupportMappersTests: XCTestCase {

    private let device = SupportDevice(
        vendorId: 0x057E,
        productId: 0x2019,
        product: "N64 Controller",
        manufacturer: "",
        transport: "USB",
        descriptor: []
    )

    private func facts(_ capture: SupportCaptureState, known: Bool = true, key: String = "057e:2019") -> ShellFacts {
        var facts = ShellFacts()
        facts.supportCapture = SupportCaptureFacts(deviceKey: key, known: known, capture: capture)
        return facts
    }

    private func found() -> SupportCaptureState {
        reduceSupportCapture(SupportCaptureState(), .deviceFound(device))
    }

    func testThePageSaysWhatItDoesAndLooksForTheDeviceFirst() {
        let state = helpSupportPageState(deviceKey: "057e:2019", facts: ShellFacts())
        XCTAssertEqual(
            state.intro,
            "Dish records what this controller sends as you press each control. Nothing leaves this Mac unless you paste it."
        )
        XCTAssertEqual(state.content, .waiting("Looking for the controller. Make sure it is connected."))
        XCTAssertEqual(helpSupportContent(deviceKey: "057e:2019", facts(SupportCaptureState()).supportCapture), state.content)
        XCTAssertEqual(
            helpSupportContent(deviceKey: "057e:2019", facts(found(), key: "other").supportCapture),
            state.content,
            "another device's capture"
        )
    }

    func testAKeyThatNamesNoDeviceSaysSo() {
        let content = helpSupportContent(deviceKey: "x", facts(SupportCaptureState(), known: false, key: "x").supportCapture)
        XCTAssertEqual(content, .waiting("Dish can’t tell which device this is."))
    }

    func testAStepNamesTheDeviceTheControlAndTheReportsSeen() {
        let seen = reduceSupportCapture(found(), .reports([[0x30], [0x31]]))
        let content = helpSupportContent(deviceKey: "057e:2019", facts(seen).supportCapture)
        XCTAssertEqual(content, .step(SupportStepState(
            device: "N64 Controller · 057e:2019",
            progress: "Step 1 of 14",
            prompt: "Leave the controller untouched",
            seen: "Reports seen: 2",
            next: "Next",
            skip: "Skip"
        )))
        let nameless = SupportDevice(vendorId: 1, productId: 2, product: "", manufacturer: "", transport: "", descriptor: [])
        XCTAssertEqual(supportDeviceLine(nameless), "0001:0002")
    }

    func testEveryStepHasItsPrompt() {
        let prompts = SupportStep.allCases.map { supportStepPrompt($0) }
        XCTAssertEqual(prompts, [
            "Leave the controller untouched", "Press A", "Press B", "Press X", "Press Y",
            "Press the left shoulder button", "Press the right shoulder button",
            "Pull the left trigger", "Pull the right trigger", "Press Select", "Press Start",
            "Press up on the d-pad", "Move the left stick up", "Move the right stick up"
        ])
    }

    func testTheResultIsTheReportWithCopyAndTheIssueLink() {
        var capture = found()
        for _ in SupportStep.allCases {
            capture = reduceSupportCapture(capture, .skip)
        }
        guard case let .finished(result) = helpSupportContent(deviceKey: "057e:2019", facts(capture).supportCapture) else {
            return XCTFail("the sequence is done")
        }
        XCTAssertEqual(result.text, supportReportText(capture))
        XCTAssertEqual(result.copy, "Copy")
        XCTAssertEqual(result.copied, "Report copied.")
        XCTAssertEqual(result.issue, "Open a GitHub issue")
        XCTAssertEqual(result.issueURL, supportIssueURL(device))
        XCTAssertEqual(result.note, "Copy the report, then paste it into the issue.")
    }
}
