// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreHaptics
import Foundation
import GameController

/// Per-controller haptic actuator. Wraps `GCController.haptics` + two
/// `CHHapticEngine` instances (one per locator) so the satellite-driven
/// rumble update can fan out to both motors with a single call.
///
/// Vibration only — the light bar is a separate concern with its own return
/// path (`MSG_LIGHTBAR` → `applyLightbar` in `GameControllerInput`); this
/// actuator never touches `controller.light`.
///
/// Design notes:
///
/// * GameController.framework's haptics surface is locator-based: the strong
///   (low-frequency) motor lives at `.leftHandle`, the weak (high-frequency)
///   motor at `.rightHandle`. Trigger haptics are exposed at `.leftTrigger`
///   / `.rightTrigger` but the satellite wire format doesn't currently carry
///   trigger magnitudes — Xbox 360 doesn't have them — so we only wire up
///   the two handle locators.
///
/// * Engines are kept *started*. Each `apply` call rebuilds a tiny
///   `CHHapticPattern` and feeds it to a fresh per-call player. This is what
///   Apple's own GCController docs recommend: starting/stopping the engine
///   per call adds ~5–10 ms of latency that defeats the wire-side coalescing.
///
/// * Engines stop themselves on idle; we install a reset handler that
///   transparently restarts them so the next `apply` doesn't drop on the
///   floor.
///
/// * If the controller doesn't expose haptics (legacy MFi pads, some PS3
///   adapters), `init?` fails and the caller skips actuation.
final class RumbleActuator {
    private let controller: GCController
    private var leftEngine: CHHapticEngine?
    private var rightEngine: CHHapticEngine?

    init?(controller: GCController) {
        // GCController.haptics is `nil` on pads that don't expose dual-motor
        // rumble through GameController.framework. Bail early so the caller
        // doesn't keep retrying.
        guard controller.haptics != nil else { return nil }
        self.controller = controller

        leftEngine = makeEngine(locality: .leftHandle)
        rightEngine = makeEngine(locality: .rightHandle)
        // If both locators failed to vend an engine the controller doesn't
        // really support rumble — treat as "no haptics".
        if leftEngine == nil, rightEngine == nil { return nil }
    }

    func shutdown() {
        leftEngine?.stop(completionHandler: nil)
        rightEngine?.stop(completionHandler: nil)
        leftEngine = nil
        rightEngine = nil
    }

    /// `durationMs == 0` "continuous" hold length. The protocol's 0 means
    /// "keep the magnitudes applied until the next rumble packet", but a
    /// `CHHapticEvent` needs a concrete duration — so a continuous packet
    /// plays for this long and is replaced by whatever the next packet brings.
    /// 30 s is CoreHaptics' practical continuous-event ceiling and far longer
    /// than the gap between rumble updates from a vibrating game.
    private static let continuousHoldSeconds: TimeInterval = 30.0

    /// Fire-and-forget vibration. `strong` drives the low-frequency motor
    /// (`.leftHandle`); `weak` drives the high-frequency motor
    /// (`.rightHandle`). Both magnitudes are normalised from the wire-format
    /// 0..65535 range to CHHaptic's 0..1 intensity.
    ///
    /// `durationMs == 0` is the protocol's *continuous* mode (`RumbleReport`
    /// in `satellite/src/core/types.h`: "0 = continuous (until next packet)") —
    /// NOT "stop". The motors are driven and held until the next rumble packet
    /// for this controller replaces them; a genuine stop arrives as an explicit
    /// packet with zero magnitudes. Treating 0 as "no actuation" (the previous
    /// behaviour) silently dropped every continuous-rumble packet — and a game
    /// holding the motors across frames commonly sends exactly `durationMs == 0`.
    ///
    /// The light bar is deliberately *not* handled here — it has its own
    /// return path (`MSG_LIGHTBAR` → `GameControllerInput.applyLightbar`),
    /// gated independently of the Rumble setting.
    func apply(strong: UInt16, weak: UInt16, durationMs: UInt16) {
        let duration: TimeInterval = durationMs == 0
            ? Self.continuousHoldSeconds
            : TimeInterval(durationMs) / 1000.0
        play(engine: leftEngine, magnitude: strong, duration: duration)
        play(engine: rightEngine, magnitude: weak, duration: duration)
    }

    // MARK: - Internals

    private func makeEngine(locality: GCHapticsLocality) -> CHHapticEngine? {
        guard let engine = controller.haptics?.createEngine(withLocality: locality) else {
            return nil
        }
        // Auto-restart after the engine times out (10 s of inactivity by
        // default) or the system reclaims its resources for a higher-priority
        // app. Without this the second wave of rumble after a long idle silently
        // fails.
        engine.resetHandler = { [weak engine] in
            try? engine?.start()
        }
        engine.stoppedHandler = { _ in
            // No-op: resetHandler picks up restart duty.
        }
        do {
            try engine.start()
            return engine
        } catch {
            return nil
        }
    }

    private func play(engine: CHHapticEngine?, magnitude: UInt16, duration: TimeInterval) {
        guard let engine else { return }
        // 0..65535 → 0..1; CoreHaptics intensity is a normalized float.
        let intensity = Float(magnitude) / 65535.0
        if intensity == 0.0 {
            // Player with intensity 0 is a no-op but also a "stop" hint —
            // pre-existing players in the engine will still elapse.
            return
        }
        // `hapticContinuous` is the right pattern for sustained motor drive.
        // `hapticSharpness` 0.5 is a neutral default; CoreHaptics uses it to
        // bias the spectrum on supported devices and ignores it otherwise.
        let intensityParam = CHHapticEventParameter(
            parameterID: .hapticIntensity, value: intensity
        )
        let sharpnessParam = CHHapticEventParameter(
            parameterID: .hapticSharpness, value: 0.5
        )
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensityParam, sharpnessParam],
            relativeTime: 0,
            duration: duration
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // CoreHaptics throws on malformed patterns / dead engines. We've
            // got nothing useful to do at this level — the next packet will
            // overwrite our state anyway.
        }
    }
}
