// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The IO-thread halves of controller audio: the two down lanes decoded off
// the receive thread into rings the device reads, and the microphone's
// windows off the device thread into the encoder. `ControllerAudioEngine`
// owns one of each per bound controller.

import DishCore
import Foundation

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

    /// One locally made window (the inspector's tone) straight into a lane's
    /// ring, behind whatever the wire queued.
    func enqueueLocal(_ lane: Lane, _ pcm: [Float]) {
        guard let ring = rings[lane] else { return }
        queue.async { ring.write(pcm) }
    }

    /// A fresh pad on the satellite's side (a slot plugged again, or a new
    /// session) starts its lanes' sequence numbers over, so the windows start
    /// over too, or every frame of the new stream would read as late behind
    /// the old playhead for as long as the old count ran ahead. The decoders
    /// go with them: a decoder carries the previous stream's filter state and
    /// concealment history. The lanes stay as the plan set them.
    func restart() {
        os_unfair_lock_lock(&lock)
        windows = [.speaker: AudioJitterWindow(), .haptic: AudioJitterWindow()]
        decoders = [:]
        os_unfair_lock_unlock(&lock)
        for ring in rings.values {
            ring.clear()
        }
    }

    func clear() {
        restart()
        os_unfair_lock_lock(&lock)
        enabled = [.speaker: false, .haptic: false]
        os_unfair_lock_unlock(&lock)
    }
}

/// The microphone: samples from the device's IO thread into a window; a
/// full window is encoded and sent on its own queue while delivering, and
/// metered while the inspector listens, which sends nothing.
final class MicCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dish.audio.capture", qos: .userInteractive)
    private var window = [Float](repeating: 0, count: AudioWire.samplesPerChannel)
    private var filled = 0
    private var lock = os_unfair_lock_s()
    private let delivering = AtomicBool(false)
    private let metering = AtomicBool(false)
    private let levelSink = LockedBox<((MicLevel) -> Void)?>(nil)
    private var encoder: OpusEncoder?
    private(set) var sent = 0
    var onWindow: ((Data) -> Void)?

    var onLevel: ((MicLevel) -> Void)? {
        get { levelSink.get() }
        set { levelSink.set(newValue) }
    }

    func setDelivering(_ on: Bool) {
        delivering.set(on)
    }

    func setMetering(_ on: Bool) {
        metering.set(on)
    }

    /// IO thread: copy in; a completed window is handed to the queue.
    func push(_ buffer: UnsafePointer<Float>, frames: Int) {
        guard delivering.get() || metering.get() else { return }
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
                queue.async { [self] in handle(complete) }
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Capture queue: the meter reads the window, the host gets it encoded;
    /// each only while its gate is open at that moment.
    private func handle(_ samples: [Float]) {
        if metering.get() { onLevel?(MicLevel.of(samples)) }
        if delivering.get() { encodeAndSend(samples) }
    }

    private func encodeAndSend(_ samples: [Float]) {
        let encoder = encoder ?? OpusEncoder(channels: AudioWire.micChannels, bitrate: AudioWire.micBitrate)
        self.encoder = encoder
        guard let opus = encoder?.encode(samples) else { return }
        sent += 1
        onWindow?(opus)
    }
}
