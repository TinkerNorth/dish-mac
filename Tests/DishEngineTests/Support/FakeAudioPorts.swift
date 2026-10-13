// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreAudio
import Foundation
@testable import DishEngine

/// The device's IO thread, played by the test: pull windows out of an
/// output, push samples into an input.
final class FakeAudioOutput: AudioOutputPort {
    let device: AudioObjectID
    let channels: Int
    let render: AudioRender
    private(set) var started = false

    init(device: AudioObjectID, channels: Int, render: @escaping AudioRender) {
        self.device = device
        self.channels = channels
        self.render = render
    }

    func start() -> Bool {
        started = true
        return true
    }

    func stop() {
        started = false
    }

    /// One pull of `frames` interleaved frames, as the device would ask.
    func pull(frames: Int) -> [Float] {
        var buffer = [Float](repeating: 0, count: frames * channels)
        buffer.withUnsafeMutableBufferPointer { body in
            guard let base = body.baseAddress else { return }
            render(base, frames)
        }
        return buffer
    }
}

final class FakeAudioInput: AudioInputPort {
    let device: AudioObjectID
    let channels: Int
    let capture: AudioCapture
    private(set) var started = false

    init(device: AudioObjectID, channels: Int, capture: @escaping AudioCapture) {
        self.device = device
        self.channels = channels
        self.capture = capture
    }

    func start() -> Bool {
        started = true
        return true
    }

    func stop() {
        started = false
    }

    func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { body in
            guard let base = body.baseAddress else { return }
            capture(base, samples.count / channels)
        }
    }
}

final class FakeAudioPorts: AudioPortFactory {
    private(set) var outputs: [FakeAudioOutput] = []
    private(set) var inputs: [FakeAudioInput] = []
    var refuseInput = false

    func makeOutput(device: AudioObjectID, channels: Int, render: @escaping AudioRender) -> AudioOutputPort? {
        let output = FakeAudioOutput(device: device, channels: channels, render: render)
        outputs.append(output)
        return output
    }

    func makeInput(device: AudioObjectID, channels: Int, capture: @escaping AudioCapture) -> AudioInputPort? {
        guard !refuseInput else { return nil }
        let input = FakeAudioInput(device: device, channels: channels, capture: capture)
        inputs.append(input)
        return input
    }
}
