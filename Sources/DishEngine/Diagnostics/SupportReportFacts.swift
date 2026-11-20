// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The second cut's facts for the bundle, folded from what the engine holds
// at the press: the person's report, each pad's input and output, each
// host's session and what it said of itself, and the Mac's conditions. Pure
// folds; the core's builder makes the file.

import DishCore
import Foundation

/// What the person filled in on the report page.
package struct SupportReportDraft: Equatable {
    package let category: SupportReportCategory
    package let text: String
    /// The slot the report concerns; nil for none.
    package let slotId: String?

    package init(category: SupportReportCategory, text: String, slotId: String?) {
        self.category = category
        self.text = text
        self.slotId = slotId
    }
}

/// What preparing a report gathered: each live link's own view of itself
/// and the Mac's conditions.
package struct ReportPreparation: Equatable {
    package let snapshots: [String: HostSnapshotVerdict]
    package let conditions: BundleDeviceConditions

    package init(snapshots: [String: HostSnapshotVerdict], conditions: BundleDeviceConditions) {
        self.snapshots = snapshots
        self.conditions = conditions
    }
}

/// One pad's feed and feedback as read at the press.
package struct PadPathReading: Equatable {
    package let latest: LatestInputFacts?
    package let rateHz: Int?
    package let output: PadOutputCounts

    package init(latest: LatestInputFacts?, rateHz: Int?, output: PadOutputCounts) {
        self.latest = latest
        self.rateHz = rateHz
        self.output = output
    }
}

/// A pad's report count and the last report published.
package struct LatestInputFacts: Equatable {
    package let frames: UInt64
    package let last: GamepadReport?

    package init(frames: UInt64, last: GamepadReport?) {
        self.frames = frames
        self.last = last
    }
}

/// The report's words, its category and the controller it names.
func supportReport(_ draft: SupportReportDraft, pads: [PadDiagnostics]) -> SupportReport {
    let pad = draft.slotId.flatMap { slotId in pads.first { $0.slot.id == slotId } }
    return SupportReport(
        category: draft.category,
        text: reportText(draft.text),
        controller: pad.map { reportedController(record: $0.record, product: $0.device?.name ?? $0.slot.name) }
    )
}

/// Where the Mac sends a pad's rumble, by the carriage its path settled.
func rumbleTarget(_ carriage: RumbleCarriage?) -> BundleOutputTarget {
    switch carriage {
    case .ownReport: .directUsb
    case .ownController, .carried, nil: .framework
    case .carrierHasNoMotors, .noCarrier, .ambiguous, .notCarried: .none
    }
}

func micLedWord(_ state: MicLedState) -> String {
    switch state {
    case .off: "off"
    case .on: "on"
    case .pulse: "pulse"
    }
}

/// What came out of the pad, lane by lane, its voices from the audio plan.
func bundlePadOutput(_ pad: PadDiagnostics, counts: PadOutputCounts) -> BundlePadOutput {
    let audio = pad.audio
    let state = audio?.state
    let routed = audio?.route?.verdict == .routed
    let counters = audio?.counters ?? AudioCounters()
    let speaker = audio.map { _ in
        bundleVoice(
            open: state?.plan.speakerVoice ?? false,
            refused: state?.playbackRefused ?? false,
            routed: routed,
            frames: counters.speakerPlayed
        )
    }
    let haptics = audio.map { _ in
        bundleVoice(
            open: state?.plan.hapticVoice ?? false,
            refused: state?.playbackRefused ?? false,
            routed: routed,
            frames: counters.hapticPlayed
        )
    }
    return BundlePadOutput(
        counts: counts,
        rumbleTarget: rumbleTarget(pad.inputPath?.rumble),
        lastWrite: pad.inputPath?.lastWrite,
        micLed: state?.micLed.map(micLedWord),
        speaker: speaker,
        haptics: haptics
    )
}

/// What went into the pad: nil before its feed was read.
func bundlePadInput(_ reading: PadPathReading) -> BundlePadInput? {
    reading.latest.map { BundlePadInput(frames: $0.frames, rateHz: reading.rateHz, last: $0.last) }
}
