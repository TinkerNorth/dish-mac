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

    package init(plan: AudioPlan = .silent, micLed: MicLedState? = nil) {
        self.plan = plan
        self.micLed = micLed
    }
}

@MainActor
package final class ControllerAudioEngine: StateSource<[String: ControllerAudioState]> {

    private let ports: AudioPortFactory
    private var slots: [String: SlotAudio] = [:]

    init(ports: AudioPortFactory = CoreAudioPorts()) {
        self.ports = ports
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
        setState(slots.mapValues { ControllerAudioState(plan: $0.plan, micLed: $0.micLed) })
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

    package init(speakerPlayed: Int = 0, speakerConcealed: Int = 0, hapticPlayed: Int = 0, hapticConcealed: Int = 0, micSent: Int = 0) {
        self.speakerPlayed = speakerPlayed
        self.speakerConcealed = speakerConcealed
        self.hapticPlayed = hapticPlayed
        self.hapticConcealed = hapticConcealed
        self.micSent = micSent
    }
}

/// One controller's voices and microphone.
@MainActor
private final class SlotAudio {
    private let ports: AudioPortFactory
    private let onLamp: (String, MicLedState) -> Void
    private var slotId = ""
    private var connection: WifiConnection?
    private(set) var plan = AudioPlan.silent
    var micLed: MicLedState?

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
            micSent: capture.sent
        )
    }

    func apply(_ binding: AudioBinding) {
        slotId = binding.slotId
        let next = audioPlan(binding.facts)
        if connection !== binding.connection {
            connection = binding.connection
            installHandlers(binding.connection)
        }
        reconcileOutput(binding, next)
        reconcileInput(binding, next)
        plan = next
    }

    func close() {
        output?.stop()
        output = nil
        input?.stop()
        input = nil
        capture.setDelivering(false)
        playout.clear()
        plan = .silent
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
    /// wanted, and closes when neither is; a lane the plan refuses stays
    /// silent in the ring.
    private func reconcileOutput(_ binding: AudioBinding, _ next: AudioPlan) {
        let wantsOutput = next.speakerVoice || next.hapticVoice
        guard let route = binding.route, wantsOutput else {
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

    /// The microphone captures while the plan says so; the mute flag is read
    /// per window, so a mute lands within one.
    private func reconcileInput(_ binding: AudioBinding, _ next: AudioPlan) {
        guard let route = binding.route, next.micArmed else {
            input?.stop()
            input = nil
            capture.setDelivering(false)
            return
        }
        capture.setDelivering(next.capture)
        guard input == nil else { return }
        let capture = capture
        let connection = binding.connection
        capture.onWindow = { opus in connection.sendMicAudio(opus: opus) }
        input = ports.makeInput(device: route.device.id, channels: AudioWire.micChannels) { buffer, frames in
            capture.push(buffer, frames: frames)
        }
        if input?.start() != true { input = nil }
    }
}

/// The two down lanes: a bounded queue off the receive thread, decode on
/// one serial queue through a jitter window per lane, and a ring per lane
/// the device's IO thread reads.
final class LanePlayout: @unchecked Sendable {
    enum Lane: CaseIterable {
        case speaker
        case haptic
    }

    struct Counters: Equatable {
        var played = 0
        var concealed = 0
    }

    private let queue = DispatchQueue(label: "dish.audio.decode", qos: .userInteractive)
    private var windows: [Lane: AudioJitterWindow] = [.speaker: AudioJitterWindow(), .haptic: AudioJitterWindow()]
    private var decoders: [Lane: OpusDecoder] = [:]
    private var rings: [Lane: WindowRing] = [.speaker: WindowRing(channels: 2), .haptic: WindowRing(channels: 2)]
    private var laneCounters: [Lane: Counters] = [.speaker: Counters(), .haptic: Counters()]
    private var enabled: [Lane: Bool] = [.speaker: false, .haptic: false]
    private let pending = AtomicInt(0)
    private var lock = os_unfair_lock_s()
    /// Frames queued but not yet decoded; the oldest go first and the
    /// newest are dropped past this depth (160 ms), as dish-android does.
    static let queueDepth = 8

    func setLanes(speaker: Bool, haptic: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        enabled = [.speaker: speaker, .haptic: haptic]
    }

    /// Receive thread: hand the frame to the decode queue, bounded.
    func enqueue(_ lane: Lane, _ frame: AudioFrame) {
        guard pending.get() < Self.queueDepth else { return }
        _ = pending.incrementAndGet()
        queue.async { [self] in
            pending.set(pending.get() - 1)
            decode(lane, frame)
        }
    }

    private func decode(_ lane: Lane, _ frame: AudioFrame) {
        os_unfair_lock_lock(&lock)
        guard enabled[lane] == true, var window = windows[lane], let ring = rings[lane] else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let decoder = decoders[lane] ?? OpusDecoder(channels: 2)
        decoders[lane] = decoder
        let events = window.push(frame)
        windows[lane] = window
        var counters = laneCounters[lane] ?? Counters()
        os_unfair_lock_unlock(&lock)
        guard let decoder else { return }
        for event in events {
            switch event {
            case let .packet(opus):
                ring.write(decoder.decode(opus))
                counters.played += 1
            case .gap:
                ring.write(decoder.decode(nil))
                counters.concealed += 1
            case .late:
                break
            }
        }
        os_unfair_lock_lock(&lock)
        laneCounters[lane] = counters
        os_unfair_lock_unlock(&lock)
    }

    /// IO thread: the speaker lane on channels 1 and 2, the haptics lanes on
    /// 3 and 4 when the device has them.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        buffer.update(repeating: 0, count: frames * channels)
        guard let speaker = rings[.speaker] else { return }
        var pair = [Float](repeating: 0, count: frames * 2)
        read(speaker, into: &pair)
        interleave(pair, into: buffer, frames: frames, channels: channels, offset: 0)
        guard channels >= 4, let haptic = rings[.haptic] else { return }
        read(haptic, into: &pair)
        interleave(pair, into: buffer, frames: frames, channels: channels, offset: 2)
    }

    private func read(_ ring: WindowRing, into pair: inout [Float]) {
        let count = pair.count
        pair.withUnsafeMutableBufferPointer { body in
            guard let base = body.baseAddress else { return }
            ring.read(into: base, count: count)
        }
    }

    private func interleave(_ pair: [Float], into buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int, offset: Int) {
        for frame in 0 ..< frames {
            buffer[frame * channels + offset] = pair[frame * 2]
            buffer[frame * channels + offset + 1] = pair[frame * 2 + 1]
        }
    }

    func counters(_ lane: Lane) -> Counters {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return laneCounters[lane] ?? Counters()
    }

    func queuedWindows(_ lane: Lane) -> Int {
        rings[lane]?.queuedWindows ?? 0
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        windows = [.speaker: AudioJitterWindow(), .haptic: AudioJitterWindow()]
        enabled = [.speaker: false, .haptic: false]
        os_unfair_lock_unlock(&lock)
        for ring in rings.values {
            ring.clear()
        }
    }
}

/// The microphone: samples from the device's IO thread into a window; a
/// full window is encoded and sent on its own queue while delivering.
final class MicCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dish.audio.capture", qos: .userInteractive)
    private var window = [Float](repeating: 0, count: AudioWire.samplesPerChannel)
    private var filled = 0
    private var lock = os_unfair_lock_s()
    private let delivering = AtomicBool(false)
    private var encoder: OpusEncoder?
    private(set) var sent = 0
    var onWindow: ((Data) -> Void)?

    func setDelivering(_ on: Bool) {
        delivering.set(on)
    }

    /// IO thread: copy in; a completed window is handed to the queue.
    func push(_ buffer: UnsafePointer<Float>, frames: Int) {
        guard delivering.get() else { return }
        os_unfair_lock_lock(&lock)
        var consumed = 0
        while consumed < frames {
            let room = AudioWire.samplesPerChannel - filled
            let take = min(room, frames - consumed)
            for index in 0 ..< take {
                window[filled + index] = buffer[consumed + index]
            }
            filled += take
            consumed += take
            if filled == AudioWire.samplesPerChannel {
                let complete = window
                filled = 0
                queue.async { [self] in encodeAndSend(complete) }
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    private func encodeAndSend(_ samples: [Float]) {
        guard delivering.get() else { return }
        let encoder = encoder ?? OpusEncoder(channels: AudioWire.micChannels, bitrate: AudioWire.micBitrate)
        self.encoder = encoder
        guard let opus = encoder?.encode(samples) else { return }
        sent += 1
        onWindow?(opus)
    }
}
