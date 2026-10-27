// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// "Help support this controller": the guided sequence one step at a time,
/// then the report as a read-only block with Copy and "Open a GitHub issue".
/// Nothing is sent: the issue opens with its title, and the user pastes the
/// copied report as its body.
struct HelpSupportPageState: Equatable {
    let intro: String
    let content: HelpSupportContent
}

enum HelpSupportContent: Equatable {
    /// Looking for the device, or a key that names none.
    case waiting(String)
    case step(SupportStepState)
    case finished(SupportResultState)
}

struct SupportStepState: Equatable {
    /// "Nintendo N64 Controller · 057e:2019".
    let device: String
    let progress: String
    let prompt: String
    let seen: String
    let next: String
    let skip: String
}

struct SupportResultState: Equatable {
    let text: String
    let copy: String
    let copied: String
    let issue: String
    let issueURL: URL?
    let note: String
}

func helpSupportPageState(deviceKey: String, facts: ShellFacts, words: L10n = .app) -> HelpSupportPageState {
    HelpSupportPageState(
        intro: words.helpSupportIntro,
        content: helpSupportContent(deviceKey: deviceKey, facts.supportCapture, words: words)
    )
}

func helpSupportContent(deviceKey: String, _ facts: SupportCaptureFacts?, words: L10n = .app) -> HelpSupportContent {
    guard let facts, facts.deviceKey == deviceKey else { return .waiting(words.lookingForTheController) }
    guard facts.known else { return .waiting(words.unknownSupportDevice) }
    let capture = facts.capture
    switch capture.phase {
    case .searching: return .waiting(words.lookingForTheController)
    case .stepping: return .step(supportStep(capture, words: words))
    case .finished: return .finished(supportResult(capture, words: words))
    }
}

func supportStep(_ capture: SupportCaptureState, words: L10n = .app) -> SupportStepState {
    let device = capture.device.map(supportDeviceLine) ?? ""
    let prompt = capture.step.map { supportStepPrompt($0, words: words) } ?? ""
    return SupportStepState(
        device: device,
        progress: words.stepOf(capture.stepIndex + 1, SupportStep.allCases.count),
        prompt: prompt,
        seen: words.reportsSeen(capture.current.count),
        next: words.next,
        skip: words.skip
    )
}

/// The product as the device names itself, and its USB identity.
func supportDeviceLine(_ device: SupportDevice) -> String {
    device.product.isEmpty ? device.hardwareKey : "\(device.product) · \(device.hardwareKey)"
}

func supportResult(_ capture: SupportCaptureState, words: L10n = .app) -> SupportResultState {
    SupportResultState(
        text: supportReportText(capture),
        copy: words.copy,
        copied: words.reportCopied,
        issue: words.openAGitHubIssue,
        issueURL: capture.device.flatMap(supportIssueURL),
        note: words.pasteTheReportIntoTheIssue
    )
}

func supportStepPrompt(_ step: SupportStep, words: L10n = .app) -> String {
    switch step {
    case .atRest: words.stepAtRest
    case .pressA: words.stepPressA
    case .pressB: words.stepPressB
    case .pressX: words.stepPressX
    case .pressY: words.stepPressY
    case .leftShoulder: words.stepLeftShoulder
    case .rightShoulder: words.stepRightShoulder
    case .leftTrigger: words.stepLeftTrigger
    case .rightTrigger: words.stepRightTrigger
    case .select: words.stepSelect
    case .start: words.stepStart
    case .dpadUp: words.stepDpadUp
    case .leftStickUp: words.stepLeftStickUp
    case .rightStickUp: words.stepRightStickUp
    }
}
