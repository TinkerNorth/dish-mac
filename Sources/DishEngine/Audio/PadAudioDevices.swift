// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Where a pad's own audio function lives on a Mac: a DualSense on USB shows
// up as a USB audio device named after itself, with the 4-channel OUT stream
// (speaker left and right, then the two haptics lanes) and the mono mic IN;
// a DualShock 4 v2 as "Wireless Controller" with a headset stereo out and no
// haptics lanes. Over Bluetooth neither exposes an audio function. The
// catalog reads the HAL; the choice is pure.

import CoreAudio
import DishCore
import Foundation

/// One Core Audio device as the catalog reads it.
package struct AudioDeviceFacts: Equatable {
    package let id: AudioObjectID
    package let uid: String
    package let name: String
    package let isUSB: Bool
    package let inputChannels: Int
    package let outputChannels: Int

    package init(id: AudioObjectID, uid: String, name: String, isUSB: Bool, inputChannels: Int, outputChannels: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isUSB = isUSB
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }
}

/// A pad's audio function: the device and the family it belongs to.
package struct PadAudioFunction: Equatable {
    package let device: AudioDeviceFacts
    package let family: PadFamily

    package init(device: AudioDeviceFacts, family: PadFamily) {
        self.device = device
        self.family = family
    }

    package var hasMic: Bool {
        device.inputChannels >= AudioWire.micChannels
    }

    package var hasSpeaker: Bool {
        device.outputChannels >= AudioWire.speakerChannels
    }

    /// The haptics lanes are channels 3 and 4 of the DualSense OUT stream.
    package var hasHapticLanes: Bool {
        family == .dualSense && device.outputChannels >= AudioWire.speakerChannels + AudioWire.hapticChannels
    }
}

/// The pad audio functions among the system's devices, in the HAL's order.
/// Only USB devices qualify; the name says which family built them.
package func padAudioFunctions(in devices: [AudioDeviceFacts]) -> [PadAudioFunction] {
    devices.compactMap { device in
        guard device.isUSB, let family = padFamily(ofAudioDeviceNamed: device.name) else { return nil }
        return PadAudioFunction(device: device, family: family)
    }
}

/// The product strings the two Sony pads present on their audio functions.
func padFamily(ofAudioDeviceNamed name: String) -> PadFamily? {
    let lowered = name.lowercased()
    if lowered.contains("dualsense") { return .dualSense }
    if lowered.contains("dualshock") || lowered == "wireless controller" || lowered.hasPrefix("wireless controller ") { return .dualShock4 }
    return nil
}

/// Reads the HAL. Every property read is best effort: a device that answers
/// nothing for a property reads as having none of it.
package enum CoreAudioDeviceCatalog {

    package static func devices() -> [AudioDeviceFacts] {
        deviceIDs().map { id in
            AudioDeviceFacts(
                id: id,
                uid: string(id, kAudioDevicePropertyDeviceUID),
                name: string(id, kAudioObjectPropertyName),
                isUSB: transport(id) == kAudioDeviceTransportTypeUSB,
                inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioObjectID) -> UInt32 {
        var property = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// The channels across every stream of one direction.
    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
