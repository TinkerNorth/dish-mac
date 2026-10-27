// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// One controller under the inspector: its input as the host sees it and as
/// the pad sent it, motion and touch, the stick tests, the rumble bench and
/// the audio tests. Arms the inspector while shown and disarms it on the
/// way out, the mic meter with it.
struct InspectorPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    let slotId: String

    private let words = L10n.app

    private var state: InspectorPageState {
        inspectorPageState(slotId: slotId, slots: model.slots, facts: model.shellFacts, micPermitted: model.micPermitted)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let path = state.path {
                    InspectorPathSection(state: path, actions: pathActions)
                }
                liveInputSection
                motionSection
                stickTestsSection
                rumbleSection
                audioSection
            }
            .padding(DishSpace.page)
        }
        .onAppear { model.pageAppeared(.inspector(slotId: slotId)) }
        .onDisappear { model.pageDisappeared(.inspector(slotId: slotId)) }
    }

    private var header: some View {
        Text(state.title)
            .font(DishFont.body)
            .foregroundColor(DishTheme.onSurface)
    }

    private var pathActions: PadPathSection.Actions {
        PadPathSection.Actions(check: checkInput, pick: pickPath, helpSupport: helpSupport)
    }

    private func checkInput() {
        model.startInputCheck(slotId: slotId)
    }

    private func pickPath(_ source: InputSource) {
        model.pickInputPath(slotId: slotId, source)
    }

    private func helpSupport() {
        navigation.send(.push(helpSupportPage(forSlot: slotId)))
    }

    // MARK: - Live input

    private var liveInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.liveInput)
            InspectorCard {
                if let live = state.live {
                    liveInput(live)
                } else {
                    note(words.waitingForFirstReport)
                }
                note(words.inputAfterDeadZones)
            }
        }
    }

    private func liveInput(_ live: LiveInputState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(live.pressed)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
            factLine(words.leftStick, live.leftStick)
            factLine(words.rightStick, live.rightStick)
            triggerLine(words.leftTrigger, live.leftTrigger)
            triggerLine(words.rightTrigger, live.rightTrigger)
            Text(live.rate)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
    }

    private func triggerLine(_ label: String, _ trigger: TriggerReadoutState) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .frame(width: 110, alignment: .leading)
            ProgressView(value: trigger.fraction)
                .tint(DishTheme.primary)
            Text(trigger.text)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: - Motion and touch

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.motionAndTouch)
            InspectorCard {
                monoLine(state.gyro)
                monoLine(state.accel)
                monoLine(state.touch)
            }
        }
    }

    // MARK: - Stick tests

    private var stickTestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.stickTests)
            InspectorCard {
                note(words.stickTestsReadRaw)
                HStack(spacing: 8) {
                    Button(words.driftTestButton) { model.startStickTest(.drift) }
                        .buttonStyle(DishOutlinedButtonStyle())
                    Button(words.rangeTestButton) { model.startStickTest(.range) }
                        .buttonStyle(DishOutlinedButtonStyle())
                }
                .disabled(!state.stickTestsEnabled)
                if let status = state.stickTestStatus {
                    monoLine(status)
                }
            }
        }
    }

    // MARK: - Rumble

    private var rumbleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.rumbleTest)
            InspectorCard {
                if let benches = state.benches {
                    note(benches.rumbleNote)
                    HStack(spacing: 8) {
                        ForEach(BuzzMotor.allCases, id: \.self) { motor in
                            Button(buzzMotorText(motor)) { model.testRumble(slotId: slotId, motor: motor) }
                                .buttonStyle(DishOutlinedButtonStyle())
                        }
                    }
                    .disabled(!benches.rumbleEnabled)
                }
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.audioTests)
            InspectorCard {
                if let benches = state.benches {
                    toneRow(benches)
                    micRow(benches)
                }
            }
        }
    }

    private func toneRow(_ benches: InspectorBenchState) -> some View {
        HStack(spacing: 8) {
            Button(words.playTone) { model.playTestTone(slotId: slotId) }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!benches.toneEnabled)
            if let note = benches.toneNote {
                Text(note)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func micRow(_ benches: InspectorBenchState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                micButton(benches.mic)
                if let note = benches.micNote {
                    Text(note)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                }
                Spacer(minLength: 0)
            }
            if let level = benches.micLevel {
                ProgressView(value: level)
                    .tint(DishTheme.primary)
            }
        }
    }

    @ViewBuilder
    private func micButton(_ button: MicTestButton) -> some View {
        switch button {
        case .stop:
            Button(words.stopWord) { model.stopMicMeter(slotId: slotId) }
                .buttonStyle(DishOutlinedButtonStyle())
        case let .start(enabled):
            Button(words.testMicrophone) { model.startMicMeter(slotId: slotId) }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!enabled)
        }
    }

    // MARK: - Pieces

    private func factLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
            Spacer(minLength: 0)
        }
    }

    private func monoLine(_ text: String) -> some View {
        Text(text)
            .font(DishFont.mono)
            .foregroundColor(DishTheme.onSurface)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DishFont.caption)
            .foregroundColor(DishTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
