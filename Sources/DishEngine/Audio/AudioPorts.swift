// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreAudio
import DishCore
import Foundation

/// The IO edges the engine opens, behind a seam so a test can play the
/// device's IO thread itself.
protocol AudioOutputPort: AnyObject {
    func start() -> Bool
    func stop()
}

protocol AudioInputPort: AnyObject {
    func start() -> Bool
    func stop()
}

protocol AudioPortFactory {
    func makeOutput(device: AudioObjectID, channels: Int, render: @escaping AudioRender) -> AudioOutputPort?
    func makeInput(device: AudioObjectID, channels: Int, capture: @escaping AudioCapture) -> AudioInputPort?
}

extension PadAudioOutput: AudioOutputPort {}
extension PadAudioInput: AudioInputPort {}

/// The real edges: the HAL output unit bound to the pad's device.
struct CoreAudioPorts: AudioPortFactory {
    func makeOutput(device: AudioObjectID, channels: Int, render: @escaping AudioRender) -> AudioOutputPort? {
        PadAudioOutput(device: device, channels: channels, render: render)
    }

    func makeInput(device: AudioObjectID, channels: Int, capture: @escaping AudioCapture) -> AudioInputPort? {
        PadAudioInput(device: device, channels: channels, render: capture)
    }
}

/// A single-producer, single-consumer ring of interleaved samples, in whole
/// 20 ms windows. The decode queue writes, the device's IO thread reads;
/// the lock is held for a copy only. It carries the fleet's cushion: play
/// starts once two windows are queued, and an underrun waits for two again.
final class WindowRing: @unchecked Sendable {
    static let startThresholdFrames = 2

    private var samples: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var playing = false
    private(set) var underruns = 0
    private var lock = os_unfair_lock_s()
    private let windowSamples: Int
    let capacityWindows: Int

    init(channels: Int, capacityWindows: Int = 8) {
        windowSamples = AudioWire.samplesPerChannel * channels
        self.capacityWindows = capacityWindows
        samples = [Float](repeating: 0, count: windowSamples * capacityWindows)
    }

    /// One window in; the oldest is dropped when the ring is full.
    func write(_ window: [Float]) {
        guard window.count == windowSamples else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if available + windowSamples > samples.count {
            readIndex = (readIndex + windowSamples) % samples.count
            available -= windowSamples
        }
        for index in 0 ..< windowSamples {
            samples[(writeIndex + index) % samples.count] = window[index]
        }
        writeIndex = (writeIndex + windowSamples) % samples.count
        available += windowSamples
        if !playing, available >= Self.startThresholdFrames * windowSamples { playing = true }
    }

    /// `count` samples out, silence while cushioning or empty.
    func read(into buffer: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard playing, available >= count else {
            if playing {
                playing = false
                underruns += 1
            }
            buffer.update(repeating: 0, count: count)
            return
        }
        for index in 0 ..< count {
            buffer[index] = samples[(readIndex + index) % samples.count]
        }
        readIndex = (readIndex + count) % samples.count
        available -= count
    }

    var queuedWindows: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return available / windowSamples
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        readIndex = 0
        writeIndex = 0
        available = 0
        playing = false
    }
}
