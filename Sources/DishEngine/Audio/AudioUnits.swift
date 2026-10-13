// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The two IO edges of controller audio on a Mac: an output unit that plays
// into one device's streams (the pad's speaker and, on a DualSense, its
// haptics lanes) and an input unit that captures one device's microphone.
// Both are the HAL output unit bound to a device, in the wire's shape
// (48 kHz float, interleaved), pulling and pushing through callbacks the
// owner provides; nothing here knows the protocol.

import AudioToolbox
import DishCore
import Foundation

/// A render callback's contract: fill `frames` interleaved samples per
/// channel, silence included, and never block.
typealias AudioRender = (_ buffer: UnsafeMutablePointer<Float>, _ frames: Int) -> Void
/// A capture callback's contract: `frames` interleaved samples arrived.
typealias AudioCapture = (_ buffer: UnsafePointer<Float>, _ frames: Int) -> Void

/// Shared plumbing: a HAL output unit on one device, with the stream format
/// the wire speaks.
private enum HALUnit {

    static func make() -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr else { return nil }
        return unit
    }

    static func format(channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: Double(AudioWire.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Every property set here is one 32-bit word: a device id or a flag.
    static func set(
        _ unit: AudioUnit,
        _ property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        _ value: UInt32
    ) -> Bool {
        var copy = value
        return AudioUnitSetProperty(unit, property, scope, element, &copy, UInt32(MemoryLayout<UInt32>.size)) == noErr
    }
}

/// Plays into one device. The owner's render callback is pulled on the
/// device's IO thread for every buffer.
final class PadAudioOutput {
    private let unit: AudioUnit
    private let render: AudioRender
    private let channels: Int

    /// Nil when the unit cannot be bound to the device in the wire's shape.
    init?(device: AudioObjectID, channels: Int, render: @escaping AudioRender) {
        guard let unit = HALUnit.make() else { return nil }
        self.unit = unit
        self.render = render
        self.channels = channels
        let output: AudioUnitElement = 0
        var format = HALUnit.format(channels: channels)
        let bound = HALUnit.set(unit, kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: output, device)
            && AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                output,
                &format,
                UInt32(MemoryLayout.size(ofValue: format))
            ) == noErr
        guard bound, installRenderCallback(unit) else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func installRenderCallback(_ unit: AudioUnit) -> Bool {
        var callback = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        return AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr
    }

    func start() -> Bool {
        AudioUnitInitialize(unit) == noErr && AudioOutputUnitStart(unit) == noErr
    }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
    }

    fileprivate func fill(_ list: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        guard let data = list.pointee.mBuffers.mData else { return }
        render(data.assumingMemoryBound(to: Float.self), Int(frames))
    }
}

private let renderProc: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    Unmanaged<PadAudioOutput>.fromOpaque(refCon).takeUnretainedValue().fill(ioData, frames: frames)
    return noErr
}

/// Captures from one device. The owner's capture callback is called on the
/// device's IO thread for every buffer that arrives.
final class PadAudioInput {
    private let unit: AudioUnit
    private let capture: AudioCapture
    private let channels: Int
    private var scratch: [Float]

    /// Nil when the unit cannot be bound to the device in the wire's shape.
    init?(device: AudioObjectID, channels: Int, render capture: @escaping AudioCapture) {
        guard let unit = HALUnit.make() else { return nil }
        self.unit = unit
        self.capture = capture
        self.channels = channels
        scratch = [Float](repeating: 0, count: 4096 * channels)
        let input: AudioUnitElement = 1
        let output: AudioUnitElement = 0
        var format = HALUnit.format(channels: channels)
        let bound = HALUnit.set(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: input, UInt32(1))
            && HALUnit.set(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: output, UInt32(0))
            && HALUnit.set(unit, kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: output, device)
            && AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                input,
                &format,
                UInt32(MemoryLayout.size(ofValue: format))
            ) == noErr
        guard bound, installInputCallback(unit) else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func installInputCallback(_ unit: AudioUnit) -> Bool {
        var callback = AURenderCallbackStruct(inputProc: inputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr
    }

    func start() -> Bool {
        AudioUnitInitialize(unit) == noErr && AudioOutputUnitStart(unit) == noErr
    }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
    }

    /// Pull the arrived buffer out of the unit into the scratch and hand it on.
    fileprivate func pull(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ time: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) {
        let needed = Int(frames) * channels
        guard needed <= scratch.count else { return }
        let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(needed * MemoryLayout<Float>.size),
                    mData: raw.baseAddress
                )
            )
            return AudioUnitRender(unit, flags, time, 1, frames, &list)
        }
        guard status == noErr else { return }
        scratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            capture(base, Int(frames))
        }
    }
}

private let inputProc: AURenderCallback = { refCon, flags, time, _, frames, _ in
    Unmanaged<PadAudioInput>.fromOpaque(refCon).takeUnretainedValue().pull(flags, time, frames: frames)
    return noErr
}
