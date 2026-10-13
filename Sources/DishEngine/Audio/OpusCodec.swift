// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The system's Opus codec through AudioToolbox, in the wire's fixed shape:
// 48 kHz, one 20 ms frame per packet, interleaved float samples on the PCM
// side. No third-party code: macOS ships the codec. AudioToolbox exposes the
// bitrate but not the encoder's FEC or DTX, and no packet-loss concealment
// on the decoder, so a concealed window plays as silence here.

import AudioToolbox
import DishCore
import Foundation

/// The PCM shape both halves speak: 48 kHz float32, interleaved.
private func pcmDescription(channels: Int) -> AudioStreamBasicDescription {
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

private func opusDescription(channels: Int) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: Double(AudioWire.sampleRate),
        mFormatID: kAudioFormatOpus,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: UInt32(AudioWire.samplesPerChannel),
        mBytesPerFrame: 0,
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 0,
        mReserved: 0
    )
}

/// The one-shot input of a conversion: handed to the converter once, then
/// "no more data", which the converter reports as our own status code.
private final class OneShotInput {
    static let drained: OSStatus = 0x6469_7368 // "dish": not a system code
    var bytes: [UInt8]
    var packets: UInt32
    var channels: UInt32
    var description: AudioStreamPacketDescription
    var delivered = false

    init(bytes: [UInt8], packets: UInt32, channels: UInt32) {
        self.bytes = bytes
        self.packets = packets
        self.channels = channels
        description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
    }
}

private let provideOnce: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDescriptions, userData in
    guard let userData else { return OneShotInput.drained }
    let input = Unmanaged<OneShotInput>.fromOpaque(userData).takeUnretainedValue()
    guard !input.delivered else {
        ioPackets.pointee = 0
        return OneShotInput.drained
    }
    input.delivered = true
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = input.channels
    ioData.pointee.mBuffers.mDataByteSize = UInt32(input.bytes.count)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input.bytes.withUnsafeBufferPointer { $0.baseAddress })
    ioPackets.pointee = input.packets
    if let outDescriptions {
        outDescriptions.pointee = withUnsafeMutablePointer(to: &input.description) { $0 }
    }
    return noErr
}

/// One 20 ms frame of interleaved samples in, one Opus packet out.
final class OpusEncoder {
    private let converter: AudioConverterRef
    private let channels: Int

    /// Nil when the system has no Opus encoder for this shape.
    init?(channels: Int, bitrate: Int) {
        var pcm = pcmDescription(channels: channels)
        var opus = opusDescription(channels: channels)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&pcm, &opus, &converter) == noErr, let converter else { return nil }
        var rate = UInt32(bitrate)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        self.converter = converter
        self.channels = channels
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// Exactly 960 samples per channel; anything else is nil, as is a frame
    /// the codec declined.
    func encode(_ samples: [Float]) -> Data? {
        guard samples.count == AudioWire.samplesPerChannel * channels else { return nil }
        let input = OneShotInput(
            bytes: samples.withUnsafeBytes { [UInt8]($0) },
            packets: UInt32(AudioWire.samplesPerChannel),
            channels: UInt32(channels)
        )
        var output = [UInt8](repeating: 0, count: 4000)
        var description = AudioStreamPacketDescription()
        var packets: UInt32 = 1
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            return AudioConverterFillComplexBuffer(
                converter, provideOnce, Unmanaged.passUnretained(input).toOpaque(), &packets, &list, &description
            )
        }
        guard status == noErr || status == OneShotInput.drained, packets == 1, description.mDataByteSize > 0 else { return nil }
        return Data(output[Int(description.mStartOffset) ..< Int(description.mStartOffset) + Int(description.mDataByteSize)])
    }
}

/// One Opus packet in, 960 interleaved samples per channel out.
final class OpusDecoder {
    private let converter: AudioConverterRef
    private let channels: Int

    init?(channels: Int) {
        var pcm = pcmDescription(channels: channels)
        var opus = opusDescription(channels: channels)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&opus, &pcm, &converter) == noErr, let converter else { return nil }
        self.converter = converter
        self.channels = channels
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// A packet decodes to one window; nil, a concealed window, is silence
    /// of the same length, as is a packet the codec rejected.
    func decode(_ packet: Data?) -> [Float] {
        let frames = AudioWire.samplesPerChannel
        guard let packet, !packet.isEmpty else { return [Float](repeating: 0, count: frames * channels) }
        let input = OneShotInput(bytes: [UInt8](packet), packets: 1, channels: UInt32(channels))
        var output = [Float](repeating: 0, count: frames * channels)
        var produced = UInt32(frames)
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            return AudioConverterFillComplexBuffer(
                converter,
                provideOnce,
                Unmanaged.passUnretained(input).toOpaque(),
                &produced,
                &list,
                nil
            )
        }
        guard status == noErr || status == OneShotInput.drained, produced > 0 else {
            return [Float](repeating: 0, count: frames * channels)
        }
        return output
    }
}
