// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Controller audio, end to end on a Mac: for every bound controller whose
// pad has an audio function, the speaker and haptics lanes the satellite
// sends are decoded on their own queue through the fleet's jitter window
// and played into the pad's device at its own width (the haptics lanes on
// channels 3 and 4, never upmixed), and the pad's microphone is captured in
// 20 ms windows, encoded and sent while every gate is open. Mute is
// enforced here: a muted controller delivers nothing. The decisions are
// `audioPlan` in the core; this is the IO that follows them.

import CoreAudio
import DishCore
import DishKernel
import Foundation

/// What one bound controller's audio needs: where its frames go and what
/// decides them.
package struct AudioBinding {
    package let slotId: String
    package let connection: WifiConnection
    package let route: PadAudioFunction?
    package let facts: AudioFacts

    package init(slotId: String, connection: WifiConnection, route: PadAudioFunction?, facts: AudioFacts) {
        self.slotId = slotId
        self.connection = connection
        self.route = route
        self.facts = facts
    }
}

/// What one controller's audio is doing, for the chips and the diagnostics.
package struct ControllerAudioState: Hashable {
    package var plan = AudioPlan.silent
    /// The lamp state the game asked for, rendered by the UI: the DualSense
    /// lamp itself is beyond GameController on a Mac.
    package var micLed: MicLedState?
    /// The inspector's test tone is on the pad's speaker right now.
    package var tonePlaying = false
    /// The inspector's microphone meter, while it listens.
    package var micMeter: MicLevel?

    package init(plan: AudioPlan = .silent, micLed: MicLedState? = nil, tonePlaying: Bool = false, micMeter: MicLevel? = nil) {
        self.plan = plan
        self.micLed = micLed
        self.tonePlaying = tonePlaying
        self.micMeter = micMeter
    }
}

@MainActor
package final class ControllerAudioEngine: StateSource<[String: ControllerAudioState]> {

    private let ports: AudioPortFactory
    private let meterMs: Int
    private var slots: [String: SlotAudio] = [:]

    /// The meter's length is injected so a test need not wait eight seconds.
    init(ports: AudioPortFactory = CoreAudioPorts(), meterMs: Int = Int(MicLevel.meterMs)) {
        self.ports = ports
        self.meterMs = meterMs
        super.init(initial: [:])
    }

    /// The bindings as they stand; every controller not listed is torn down.
    package func apply(_ bindings: [AudioBinding]) {
        let wanted = Set(bindings.map(\.slotId))
        for (slotId, slot) in slots where !wanted.contains(slotId) {
            slot.close()
            slots.removeValue(forKey: slotId)
        }
        for binding in bindings {
            let slot = slots[binding.slotId] ?? SlotAudio(ports: ports, onLamp: { [weak self] slotId, state in self?.lamp(slotId, state) })
            slots[binding.slotId] = slot
            slot.apply(binding)
        }
        publish()
    }

    private func lamp(_ slotId: String, _ state: MicLedState) {
        slots[slotId]?.micLed = state
        publish()
    }

    private func publish() {
        setState(slots.mapValues {
            ControllerAudioState(plan: $0.plan, micLed: $0.micLed, tonePlaying: $0.tonePlaying, micMeter: $0.micMeter)
        })
    }

    /// The inspector's tone on the pad's speaker: false when the pad has no
    /// speaker route, or a tone is already playing.
    package func playTone(for slotId: String) -> Bool {
        guard let slot = slots[slotId], slot.playTone(onChange: { [weak self] in self?.publish() }) else { return false }
        publish()
        return true
    }

    /// The inspector's microphone meter, listening for `meterMs` without
    /// sending a byte: false when the pad has no microphone route or the
    /// system withholds the microphone.
    package func startMicMeter(for slotId: String) -> Bool {
        guard let slot = slots[slotId], slot.startMicMeter(meterMs: meterMs, onChange: { [weak self] in self?.publish() }) else {
            return false
        }
        publish()
        return true
    }

    package func stopMicMeter(for slotId: String) {
        slots[slotId]?.stopMicMeter()
        publish()
    }

    /// The lanes' counters, for the diagnostics.
    package func counters(for slotId: String) -> AudioCounters? {
        slots[slotId]?.counters
    }
}

package struct AudioCounters: Equatable {
    package var speakerPlayed = 0
    package var speakerConcealed = 0
    package var hapticPlayed = 0
    package var hapticConcealed = 0
    package var micSent = 0
    /// The test tone's windows written so far.
    package var toneWindows = 0

    package init(
        speakerPlayed: Int = 0,
        speakerConcealed: Int = 0,
        hapticPlayed: Int = 0,
        hapticConcealed: Int = 0,
        micSent: Int = 0,
        toneWindows: Int = 0
    ) {
        self.speakerPlayed = speakerPlayed
        self.speakerConcealed = speakerConcealed
        self.hapticPlayed = hapticPlayed
        self.hapticConcealed = hapticConcealed
        self.micSent = micSent
        self.toneWindows = toneWindows
    }
}

/// Where the test tone is in its sweep; the timer's closure carries it.
private final class ToneCursor {
    var index = 0
    var phase: Float = 0
}

/// One controller's voices and microphone.
@MainActor
private final class SlotAudio {
    private let ports: AudioPortFactory
    private let onLamp: (String, MicLedState) -> Void
    private var slotId = ""
    private var connection: WifiConnection?
    private(set) var plan = AudioPlan.silent
    private var route: PadAudioFunction?
    private var facts = AudioFacts()
    var micLed: MicLedState?
    private(set) var tonePlaying = false
    private(set) var micMeter: MicLevel?
    private(set) var toneWindows = 0
    private var toneTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var metering = false

    private let playout: LanePlayout
    private let capture: MicCapture
    private var output: AudioOutputPort?
    private var input: AudioInputPort?
    private var outputChannels = 0
    private var deviceId: AudioObjectID = 0

    init(ports: AudioPortFactory, onLamp: @escaping (String, MicLedState) -> Void) {
        self.ports = ports
        self.onLamp = onLamp
        playout = LanePlayout()
        capture = MicCapture()
    }

    var counters: AudioCounters {
        AudioCounters(
            speakerPlayed: playout.counters(.speaker).played,
            speakerConcealed: playout.counters(.speaker).concealed,
            hapticPlayed: playout.counters(.haptic).played,
            hapticConcealed: playout.counters(.haptic).concealed,
            micSent: capture.sent,
            toneWindows: toneWindows
        )
    }

    func apply(_ binding: AudioBinding) {
        slotId = binding.slotId
        route = binding.route
        facts = binding.facts
        let next = audioPlan(binding.facts)
        if connection !== binding.connection {
            connection = binding.connection
            installHandlers(binding.connection)
        }
        reconcileOutput(next)
        reconcileInput(binding.connection, next)
        plan = next
    }

    func close() {
        toneTimer?.cancel()
        toneTimer = nil
        tonePlaying = false
        stopMicMeter()
        output?.stop()
        output = nil
        input?.stop()
        input = nil
        capture.setDelivering(false)
        playout.clear()
        plan = .silent
    }

    // MARK: - The inspector's tests

    /// The tone rides the speaker lane's ring one window every 20 ms, the
    /// output opened for it if no voice holds it, and closed again after the
    /// last window has had time to play.
    func playTone(onChange: @escaping () -> Void) -> Bool {
        guard let route, route.hasSpeaker, !tonePlaying else { return false }
        tonePlaying = true
        toneWindows = 0
        reconcileOutput(plan)
        guard output != nil else {
            tonePlaying = false
            return false
        }
        let cursor = ToneCursor()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(AudioWire.frameMs))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.toneTick(cursor, onChange: onChange) }
        }
        source.resume()
        toneTimer = source
        return true
    }

    /// Two windows of grace after the sweep, so the cushion and the tail
    /// play out before the output closes.
    private func toneTick(_ cursor: ToneCursor, onChange: () -> Void) {
        if cursor.index < TestTone.windows {
            playout.enqueueLocal(.speaker, TestTone.window(at: cursor.index, phase: &cursor.phase))
            toneWindows += 1
        }
        cursor.index += 1
        guard cursor.index >= TestTone.windows + 3 else { return }
        toneTimer?.cancel()
        toneTimer = nil
        tonePlaying = false
        reconcileOutput(plan)
        onChange()
    }

    /// The meter opens the microphone whether or not the host is being sent
    /// anything, and sends nothing itself: the levels stay on this Mac.
    func startMicMeter(meterMs: Int, onChange: @escaping () -> Void) -> Bool {
        guard let route, route.hasMic, facts.micPermitted, !metering else { return false }
        metering = true
        capture.setMetering(true)
        capture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micMeter = level
                onChange()
            }
        }
        if let connection {
            reconcileInput(connection, plan)
        }
        guard input != nil else {
            stopMicMeter()
            return false
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(meterMs))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.stopMicMeter()
                onChange()
            }
        }
        source.resume()
        meterTimer = source
        return true
    }

    func stopMicMeter() {
        meterTimer?.cancel()
        meterTimer = nil
        metering = false
        capture.setMetering(false)
        capture.onLevel = nil
        micMeter = nil
        if let connection {
            reconcileInput(connection, plan)
        }
    }

    private func installHandlers(_ connection: WifiConnection) {
        let playout = playout
        connection.setSpeakerAudioHandler { frame in playout.enqueue(.speaker, frame) }
        connection.setHapticAudioHandler { frame in playout.enqueue(.haptic, frame) }
        let slotId = slotId
        let onLamp = onLamp
        connection.setMicLedHandler { command in
            Task { @MainActor in onLamp(slotId, command.state) }
        }
    }

    /// The output opens at the device's own width once either voice is
    /// wanted, or the test tone plays, and closes when none is; a lane the
    /// plan refuses stays silent in the ring.
    private func reconcileOutput(_ next: AudioPlan) {
        let wantsOutput = next.speakerVoice || next.hapticVoice || tonePlaying
        guard let route, wantsOutput else {
            output?.stop()
            output = nil
            playout.clear()
            return
        }
        let channels = route.hasHapticLanes ? AudioWire.speakerChannels + AudioWire.hapticChannels : AudioWire.speakerChannels
        playout.setLanes(speaker: next.speakerVoice, haptic: next.hapticVoice)
        guard output == nil || channels != outputChannels || deviceId != route.device.id else { return }
        output?.stop()
        outputChannels = channels
        deviceId = route.device.id
        let playout = playout
        output = ports.makeOutput(device: route.device.id, channels: channels) { buffer, frames in
            playout.render(into: buffer, frames: frames, channels: channels)
        }
        if output?.start() != true { output = nil }
    }

    /// The microphone captures while the plan says so, or the meter listens;
    /// the mute flag is read per window, so a mute lands within one, and the
    /// meter never delivers.
    private func reconcileInput(_ connection: WifiConnection, _ next: AudioPlan) {
        guard let route, next.micArmed || metering else {
            input?.stop()
            input = nil
            capture.setDelivering(false)
            return
        }
        capture.setDelivering(next.capture)
        guard input == nil else { return }
        let capture = capture
        capture.onWindow = { opus in connection.sendMicAudio(opus: opus) }
        input = ports.makeInput(device: route.device.id, channels: AudioWire.micChannels) { buffer, frames in
            capture.push(buffer, frames: frames)
        }
        if input?.start() != true { input = nil }
    }
}
