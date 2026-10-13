// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// One controller under the inspector: its input as the host sees it and as
/// the pad sent it, motion and touch, the stick tests, the rumble bench and
/// the audio tests. Arms the inspector while shown and disarms it on the
/// way out, the mic meter with it.
struct InspectorView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var inspector: InputInspector
    @Environment(\.dismiss) private var dismiss
    let slotId: String

    private let words = L10n.app

    private var slot: ControllerSlot? {
        model.slots.first { $0.id == slotId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                liveInputSection
                motionSection
                stickTestsSection
                rumbleSection
                audioSection
            }
            .padding(16)
        }
        .frame(minWidth: 540, minHeight: 600)
        .background(DishTheme.background.ignoresSafeArea())
        .onAppear { model.inspect(slotId: slotId) }
        .onDisappear {
            model.stopInspecting()
            model.stopMicMeter(slotId: slotId)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(words.inspectorTitle)
                    .font(DishFont.title)
                    .foregroundColor(DishTheme.onSurface)
                Text(slot?.name ?? slotId)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Button(words.close) { dismiss() }
                .buttonStyle(DishOutlinedButtonStyle())
        }
    }

    // MARK: - Live input

    private var liveInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.liveInput)
            InspectorCard {
                if let snapshot = inspector.state.snapshot {
                    liveInput(snapshot)
                } else {
                    note(words.waitingForFirstReport)
                }
                note(words.inputAfterDeadZones)
            }
        }
    }

    private func liveInput(_ snapshot: InputSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pressedText(snapshot))
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
            factLine(words.leftStick, stickText(snapshot.leftStick))
            factLine(words.rightStick, stickText(snapshot.rightStick))
            triggerLine(words.leftTrigger, snapshot.leftTrigger)
            triggerLine(words.rightTrigger, snapshot.rightTrigger)
            Text(inputRateText(inspector.state.reportsHz))
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
    }

    private func triggerLine(_ label: String, _ fraction: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .frame(width: 110, alignment: .leading)
            ProgressView(value: Double(fraction))
                .tint(DishTheme.primary)
            Text(percentText(fraction))
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
                monoLine(gyroText(inspector.state.snapshot?.motion))
                monoLine(accelText(inspector.state.snapshot?.motion))
                monoLine(touchText(inspector.state.snapshot?.touch))
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
                .disabled(inspector.state.bench.phase == .running)
                if let status = stickTestText(inspector.state) {
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
                if let slot {
                    note(rumbleBenchNote(slot))
                    HStack(spacing: 8) {
                        ForEach(BuzzMotor.allCases, id: \.self) { motor in
                            Button(buzzMotorText(motor)) { model.testRumble(slotId: slotId, motor: motor) }
                                .buttonStyle(DishOutlinedButtonStyle())
                        }
                    }
                    .disabled(!slot.capabilities.hasRumble)
                }
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.audioTests)
            InspectorCard {
                if let slot {
                    toneRow(slot)
                    micRow(slot)
                }
            }
        }
    }

    private func toneRow(_ slot: ControllerSlot) -> some View {
        HStack(spacing: 8) {
            Button(words.playTone) { model.playTestTone(slotId: slotId) }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!slot.capabilities.hasSpeaker || slot.audio?.tonePlaying == true)
            if let note = toneNote(slot) {
                Text(note)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func micRow(_ slot: ControllerSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if slot.audio?.micMeter != nil {
                    Button(words.stopWord) { model.stopMicMeter(slotId: slotId) }
                        .buttonStyle(DishOutlinedButtonStyle())
                } else {
                    Button(words.testMicrophone) { model.startMicMeter(slotId: slotId) }
                        .buttonStyle(DishOutlinedButtonStyle())
                        .disabled(!slot.capabilities.hasMic || !model.micPermitted)
                }
                if let note = micMeterNote(slot, micPermitted: model.micPermitted) {
                    Text(note)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                }
                Spacer(minLength: 0)
            }
            if let meter = slot.audio?.micMeter {
                ProgressView(value: Double(meter.levelPercent) / 100)
                    .tint(DishTheme.primary)
            }
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

/// The inspector's card: the Diagnostics card's frame around free content.
private struct InspectorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
