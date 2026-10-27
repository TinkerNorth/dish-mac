// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// "Check the buttons": the walk's prompt for the control on screen, the
/// whole table with that control lit, Skip, Reset to defaults and the
/// desktops' note on where it is stored.
struct CheckButtonsPageState: Equatable {
    let content: CheckButtonsContent
}

enum CheckButtonsContent: Equatable {
    /// The page has appeared and the engine has not answered yet.
    case waiting
    case missing(title: String, body: String)
    case notRemappable(title: String, body: String)
    case walking(CheckButtonsWalkState)
}

struct CheckButtonsWalkState: Equatable {
    let name: String
    /// "Step 3 of 19"; nil once every control is checked.
    let progress: String?
    let prompt: String
    let rows: [RemapRowState]
    /// Skip while a step is on screen, Check again once the walk is done.
    let skip: String?
    let checkAgain: String?
    let reset: String
    let footnote: String
}

struct RemapRowState: Equatable, Identifiable {
    let id: Int
    let label: String
    let value: String
    /// The accent on the control the walk asks for.
    let ink: Color
}

func checkButtonsPageState(slotId: String, facts: ShellFacts, words: L10n = .app) -> CheckButtonsPageState {
    guard let check = facts.buttonCheck, check.slotId == slotId else { return CheckButtonsPageState(content: .waiting) }
    switch check.phase {
    case .missing:
        return CheckButtonsPageState(content: .missing(title: words.noControllersConnected, body: words.connectTheControllerToCheck))
    case .notRemappable:
        return CheckButtonsPageState(content: .notRemappable(title: words.notRemappable, body: words.notRemappableBody))
    case let .walking(walk):
        return CheckButtonsPageState(content: .walking(checkButtonsWalk(walk, name: check.name, words: words)))
    }
}

func checkButtonsWalk(_ walk: RemapAssignState, name: String, words: L10n = .app) -> CheckButtonsWalkState {
    let current = walk.step
    let rows = remapWalk.enumerated().map { index, step in
        RemapRowState(
            id: index,
            label: remapStepLabel(step, words: words),
            value: remapStepValue(step, walk.remap, words: words),
            ink: step == current ? DishTheme.primary : DishTheme.onSurface
        )
    }
    return CheckButtonsWalkState(
        name: name,
        progress: current.map { _ in words.stepOf(walk.stepIndex + 1, remapWalk.count) },
        prompt: current.map { remapPrompt($0, words: words) } ?? words.everyControlIsChecked,
        rows: rows,
        skip: current.map { _ in words.skip },
        checkAgain: current == nil ? words.checkAgain : nil,
        reset: words.resetToDefaults,
        footnote: words.storedForThisModel
    )
}

/// "Press the button you want as A"; a trigger is pulled, and each stick
/// is pushed up so its direction is known.
func remapPrompt(_ step: RemapStep, words: L10n = .app) -> String {
    switch step {
    case .assign(.leftTrigger), .assign(.rightTrigger): words.pullTheTriggerYouWantAs(remapStepLabel(step, words: words))
    case .assign: words.pressTheButtonYouWantAs(remapStepLabel(step, words: words))
    case .invert(.leftY): words.pushTheLeftStickUp
    case .invert(.rightY): words.pushTheRightStickUp
    }
}

func remapStepLabel(_ step: RemapStep, words: L10n = .app) -> String {
    switch step {
    case let .assign(target): remapTargetLabel(target, words: words)
    case .invert(.leftY): words.invertLeftStickY
    case .invert(.rightY): words.invertRightStickY
    }
}

/// The inspector's names for the wire's controls.
func remapTargetLabel(_ target: RemapTarget, words: L10n = .app) -> String {
    switch target {
    case let .button(which): remapButtonLabel(which, words: words)
    case .guide: words.buttonGuide
    case .leftStickX, .leftStickY: words.leftStick
    case .rightStickX, .rightStickY: words.rightStick
    case .leftTrigger: words.leftTrigger
    case .rightTrigger: words.rightTrigger
    }
}

func remapButtonLabel(_ which: RemapButton, words: L10n = .app) -> String {
    switch which {
    case .faceA: words.buttonA
    case .faceB: words.buttonB
    case .faceX: words.buttonX
    case .faceY: words.buttonY
    case .leftShoulder: words.buttonLB
    case .rightShoulder: words.buttonRB
    case .back: words.buttonBack
    case .start: words.buttonStart
    case .leftThumb: words.buttonL3
    case .rightThumb: words.buttonR3
    case .dpadUp: words.buttonDpadUp
    case .dpadDown: words.buttonDpadDown
    case .dpadLeft: words.buttonDpadLeft
    case .dpadRight: words.buttonDpadRight
    }
}

/// The raw source each control reads now, in the desktops' words.
func remapStepValue(_ step: RemapStep, _ remap: JoystickRemap, words: L10n = .app) -> String {
    switch step {
    case let .assign(target): remapTargetValue(target, remap, words: words)
    case .invert(.leftY): remap.invertLeftY ? words.on : words.off
    case .invert(.rightY): remap.invertRightY ? words.on : words.off
    }
}

func remapTargetValue(_ target: RemapTarget, _ remap: JoystickRemap, words: L10n = .app) -> String {
    switch target {
    case let .button(which): buttonSourceText(remap.button(which), dpadFromHat: dpadFromHat(which, remap), words: words)
    case .guide: buttonSourceText(remap.guide, dpadFromHat: false, words: words)
    case .leftStickX: axisSourceText(remap.leftStickX, words: words)
    case .leftStickY: axisSourceText(remap.leftStickY, words: words)
    case .rightStickX: axisSourceText(remap.rightStickX, words: words)
    case .rightStickY: axisSourceText(remap.rightStickY, words: words)
    case .leftTrigger: triggerSourceText(remap.leftTrigger, words: words)
    case .rightTrigger: triggerSourceText(remap.rightTrigger, words: words)
    }
}

private let dpadRemapButtons: Set<RemapButton> = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]

/// A direction with no button of its own reads the hat, when there is one.
private func dpadFromHat(_ which: RemapButton, _ remap: JoystickRemap) -> Bool {
    dpadRemapButtons.contains(which) && remap.hatIndex >= 0
}

/// A direction's own button wins over the hat, as the desktops' readout has it.
func buttonSourceText(_ index: Int, dpadFromHat: Bool, words: L10n = .app) -> String {
    if index >= 0 { return words.sourceButton(index) }
    return dpadFromHat ? words.sourceHat(RemapDefaults.hat) : words.unassigned
}

func axisSourceText(_ index: Int, words: L10n = .app) -> String {
    index >= 0 ? words.sourceAnalogAxis(index) : words.unassigned
}

func triggerSourceText(_ source: TriggerSource, words: L10n = .app) -> String {
    guard source.index >= 0 else { return words.unassigned }
    switch source.kind {
    case .axis: return words.sourceAnalogAxis(source.index)
    case .button: return words.sourceDigitalButton(source.index)
    }
}
