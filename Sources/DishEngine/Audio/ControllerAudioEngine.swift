// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Controller audio, end to end on a Mac: for every bound controller whose
// pad has an audio function, the speaker and haptics lanes the satellite
// sends are decoded on their own queue through the fleet's jitter window
// and played into the pad's device at its own width (the haptics lanes on
// channels 3 and 4, never upmixed), and the pad's microphone is captured in
// 20 ms windows, encoded and sent while every gate is open. Mute is
// enforced here: a muted controller delivers nothing. A pad no host
// carries keeps its route, so the inspector's tone and meter reach it
// from this Mac alone. The decisions are `audioPlan` in the core; this is
// the IO that follows them.

import Combine
import CoreAudio
import DishCore
import DishKernel
import Foundation

/// What one controller's audio needs: where its frames go (its satellite and
/// the controller index it holds there, none for a pad no host carries) and
/// what decides them.
package struct AudioBinding {
    package let slotId: String
    package let connection: WifiConnection?
    package let controllerIndex: Int
    package let route: PadAudioFunction?
    package let facts: AudioFacts

    package init(slotId: String, connection: WifiConnection?, controllerIndex: Int, route: PadAudioFunction?, facts: AudioFacts) {
        self.slotId = slotId
        self.connection = connection
        self.controllerIndex = controllerIndex
        self.route = route
        self.facts = facts
    }
}

/// Where the inspector's test tone plays: the pad's speaker pair, or its
/// haptics lanes.
package enum ToneLane: Hashable {
    case speaker
    case haptics
}

/// What one controller's audio is doing, for the chips and the diagnostics.
package struct ControllerAudioState: Hashable {
    package var plan = AudioPlan.silent
    /// The lamp state the game asked for, rendered by the UI: the DualSense
    /// lamp itself is beyond GameController on a Mac.
    package var micLed: MicLedState?
    /// The lane the inspector's test tone plays on right now, nil while none.
    package var tone: ToneLane?
    /// The inspector's microphone meter, while it listens.
    package var micMeter: MicLevel?
    /// The system refused the pad's output, or its microphone, at the
    /// endpoint the route names now; the satellite's descriptor follows.
    package var playbackRefused = false
    package var captureRefused = false

    package init(
        plan: AudioPlan = .silent,
        micLed: MicLedState? = nil,
        tone: ToneLane? = nil,
        micMeter: MicLevel? = nil,
        playbackRefused: Bool = false,
        captureRefused: Bool = false
    ) {
        self.plan = plan
        self.micLed = micLed
        self.tone = tone
        self.micMeter = micMeter
        self.playbackRefused = playbackRefused
        self.captureRefused = captureRefused
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
            ControllerAudioState(
                plan: $0.plan,
                micLed: $0.micLed,
                tone: $0.tone,
                micMeter: $0.micMeter,
                playbackRefused: $0.playbackRefused,
                captureRefused: $0.captureRefused
            )
        })
    }

    /// The inspector's tone on the pad's speaker or its haptics lanes: false
    /// when the pad has no route to the lane, or a tone already plays.
    /// `ended` runs once the tone has played out.
    package func playTone(for slotId: String, on lane: ToneLane, ended: @escaping () -> Void) -> Bool {
        guard let slot = slots[slotId] else { return false }
        let playing = slot.playTone(on: lane, onChange: { [weak self] in self?.publish() }, ended: ended)
        // A refused output is news even when no tone plays: the descriptor follows it.
        publish()
        return playing
    }

    /// The inspector's microphone meter, listening for `meterMs` without
    /// sending a byte: false when the pad has no microphone route or the
    /// system withholds the microphone. `ended` runs when the meter stops,
    /// on its own or by `stopMicMeter`.
    package func startMicMeter(for slotId: String, ended: @escaping () -> Void) -> Bool {
        guard let slot = slots[slotId] else { return false }
        let listening = slot.startMicMeter(meterMs: meterMs, onChange: { [weak self] in self?.publish() }, ended: ended)
        // A refused microphone is news even when no meter listens: the descriptor follows it.
        publish()
        return listening
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

/// Where the test tone is; the timer's closure carries it.
private final class ToneCursor {
    var index = 0
}

/// One controller's voices and microphone.
@MainActor
private final class SlotAudio {
    private let ports: AudioPortFactory
    private let onLamp: (String, MicLedState) -> Void
    private var slotId = ""
    private var connection: WifiConnection?
    private var controllerIndex = 0
    private(set) var plan = AudioPlan.silent
    private var route: PadAudioFunction?
    private var facts = AudioFacts()
    var micLed: MicLedState?
    private(set) var tone: ToneLane?
    private(set) var micMeter: MicLevel?
    private(set) var toneWindows = 0
    private var toneTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var metering = false
    /// What runs when the tone has played out, and when the meter stops.
    private var toneEnded: (() -> Void)?
    private var meterEnded: (() -> Void)?

    private let playout: LanePlayout
    private let capture: MicCapture
    private var applyWatch: AnyCancellable?
    private var output: AudioOutputPort?
    private var input: AudioInputPort?
    private var outputChannels = 0
    private var deviceId: AudioObjectID = 0
    /// The endpoint the system last refused an output at, and the device it
    /// refused the microphone on; nil once a start there succeeded.
    private var refusedOutput: RefusedEndpoint?
    private var refusedInputDevice: AudioObjectID?

    init(ports: AudioPortFactory, onLamp: @escaping (String, MicLedState) -> Void) {
        self.ports = ports
        self.onLamp = onLamp
        playout = LanePlayout()
        capture = MicCapture()
    }

    /// A refusal stands while the route still names the endpoint it was
    /// refused at: a replugged pad enumerates afresh, and a route that moved
    /// to another width is a new attempt.
    var playbackRefused: Bool {
        guard let route, let refusedOutput else { return false }
        return refusedOutput == RefusedEndpoint(device: route.device.id, channels: outputWidth(of: route))
    }

    var captureRefused: Bool {
        guard let route, let refusedInputDevice else { return false }
        return refusedInputDevice == route.device.id
    }

    /// The plan over the binding's facts and this slot's own refusals.
    private func planNow() -> AudioPlan {
        var current = facts
        current.playbackRefused = playbackRefused
        current.captureRefused = captureRefused
        return audioPlan(current)
    }

    private func outputWidth(of route: PadAudioFunction) -> Int {
        route.hasHapticLanes ? AudioWire.speakerChannels + AudioWire.hapticChannels : AudioWire.speakerChannels
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
        let moved = connection !== binding.connection || controllerIndex != binding.controllerIndex
        if moved {
            releaseHandlers()
            input?.stop()
            input = nil
            connection = binding.connection
            controllerIndex = binding.controllerIndex
            playout.restart()
            installHandlers(binding.connection)
        }
        reconcileOutput(planNow())
        reconcileInput(binding.connection, planNow())
        // A start that failed just now stands from here: the plan this slot reports, and the
        // caps its satellite is told, follow it at once rather than after the next binding.
        plan = planNow()
    }

    /// A test cut short by the pad's audio going away asks nothing.
    func close() {
        releaseHandlers()
        applyWatch = nil
        toneTimer?.cancel()
        toneTimer = nil
        tone = nil
        toneEnded = nil
        meterEnded = nil
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

    /// The tone rides its lane's ring one window every 20 ms, the output
    /// opened at the device's width for it if no voice holds it, and closed
    /// again after the last window has had time to play.
    func playTone(on lane: ToneLane, onChange: @escaping () -> Void, ended: @escaping () -> Void) -> Bool {
        guard let route, routeCarries(route, lane), tone == nil else { return false }
        tone = lane
        toneWindows = 0
        reconcileOutput(plan)
        guard output != nil else {
            tone = nil
            plan = planNow()
            return false
        }
        toneEnded = ended
        let cursor = ToneCursor()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(AudioWire.frameMs))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.toneTick(cursor, lane: lane, onChange: onChange) }
        }
        source.resume()
        toneTimer = source
        return true
    }

    /// Two windows of grace after the tone, so the cushion and the tail play
    /// out before the output closes.
    private func toneTick(_ cursor: ToneCursor, lane: ToneLane, onChange: () -> Void) {
        if cursor.index < TestTone.windows {
            playout.enqueueLocal(playoutLane(lane), TestTone.window(at: cursor.index))
            toneWindows += 1
        }
        cursor.index += 1
        guard cursor.index >= TestTone.windows + 3 else { return }
        toneTimer?.cancel()
        toneTimer = nil
        tone = nil
        reconcileOutput(plan)
        onChange()
        toneEnded?()
        toneEnded = nil
    }

    /// The meter opens the microphone whether or not the host is being sent
    /// anything, and sends nothing itself: the levels stay on this Mac.
    func startMicMeter(meterMs: Int, onChange: @escaping () -> Void, ended: @escaping () -> Void) -> Bool {
        guard let route, route.hasMic, facts.micPermitted, !metering else { return false }
        metering = true
        capture.setMetering(true)
        capture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micMeter = level
                onChange()
            }
        }
        reconcileInput(connection, plan)
        guard input != nil else {
            stopMicMeter()
            plan = planNow()
            return false
        }
        meterEnded = ended
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
        reconcileInput(connection, plan)
        meterEnded?()
        meterEnded = nil
    }

    /// The lanes start over each time the satellite confirms the slot plugged
    /// again: that is a fresh pad on its side, with its sequence numbers
    /// started over. The handlers sit on the pad's own index, so another pad
    /// on the same satellite keeps its own; a pad no host carries has none.
    private func installHandlers(_ connection: WifiConnection?) {
        guard let connection else {
            applyWatch = nil
            return
        }
        let playout = playout
        applyWatch = connection.applyCountPublisher(of: slotId).dropFirst().sink { _ in playout.restart() }
        let slotId = slotId
        let onLamp = onLamp
        let handlers = PadAudioHandlers(
            speaker: { frame in playout.enqueue(.speaker, frame) },
            haptic: { frame in playout.enqueue(.haptic, frame) },
            micLed: { command in Task { @MainActor in onLamp(slotId, command.state) } }
        )
        connection.setPadAudio(handlers, controllerIndex: controllerIndex)
    }

    private func releaseHandlers() {
        connection?.setPadAudio(nil, controllerIndex: controllerIndex)
    }

    /// The output opens at the device's own width once either voice is
    /// wanted, or the test tone plays, and closes when none is; a lane the
    /// plan refuses stays silent in the ring.
    private func reconcileOutput(_ next: AudioPlan) {
        let wantsOutput = next.speakerVoice || next.hapticVoice || tone != nil
        guard let route, wantsOutput else {
            output?.stop()
            output = nil
            playout.clear()
            return
        }
        let channels = outputWidth(of: route)
        playout.setLanes(speaker: next.speakerVoice, haptic: next.hapticVoice)
        guard output == nil || channels != outputChannels || deviceId != route.device.id else { return }
        output?.stop()
        outputChannels = channels
        deviceId = route.device.id
        let playout = playout
        output = ports.makeOutput(device: route.device.id, channels: channels) { buffer, frames in
            playout.render(into: buffer, frames: frames, channels: channels)
        }
        let started = output?.start() == true
        if !started {
            output = nil
        }
        refusedOutput = started ? nil : RefusedEndpoint(device: route.device.id, channels: channels)
    }

    /// The microphone captures while the plan says so, or the meter listens;
    /// the mute flag is read per window, so a mute lands within one, and the
    /// meter never delivers. A pad no host carries has nowhere to send; the
    /// input sends to the host it opened for, so a move opens it again.
    private func reconcileInput(_ connection: WifiConnection?, _ next: AudioPlan) {
        guard let route, next.micArmed || metering else {
            input?.stop()
            input = nil
            capture.setDelivering(false)
            return
        }
        capture.setDelivering(next.capture)
        guard input == nil else { return }
        let capture = capture
        let controllerIndex = controllerIndex
        capture.onWindow = { opus in connection?.sendMicAudio(opus: opus, controllerIndex: controllerIndex) }
        input = ports.makeInput(device: route.device.id, channels: AudioWire.micChannels) { buffer, frames in
            capture.push(buffer, frames: frames)
        }
        let started = input?.start() == true
        if !started {
            input = nil
        }
        refusedInputDevice = started ? nil : route.device.id
    }
}

/// Where an output was refused: the device and the width it was asked for.
private struct RefusedEndpoint: Equatable {
    let device: AudioObjectID
    let channels: Int
}

/// The route reaches the lane: a speaker pair, or the haptics lanes.
private func routeCarries(_ route: PadAudioFunction, _ lane: ToneLane) -> Bool {
    switch lane {
    case .speaker: route.hasSpeaker
    case .haptics: route.hasHapticLanes
    }
}

/// The playout ring a tone on the lane rides.
private func playoutLane(_ lane: ToneLane) -> LanePlayout.Lane {
    switch lane {
    case .speaker: .speaker
    case .haptics: .haptic
    }
}
