// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreAudio
import DishCore
import XCTest
@testable import DishEngine

/// The output edge binds to a device and runs; with no pad attached, an
/// output on a transport whose clock waits on nothing else stands in,
/// rendering silence. The input edge is never bound here: touching a
/// microphone device asks the system for permission, which no test can
/// answer.
final class AudioUnitsTests: XCTestCase {

    /// USB, which every pad's audio function is on, the Mac's own outputs,
    /// and virtual ones such as a CI runner's Null Audio Device. Never a
    /// display's or a radio's: a DisplayPort monitor's speakers can refuse
    /// to start after the display wakes.
    private static let standInTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeVirtual
    ]

    private func standInOutput() -> AudioObjectID? {
        CoreAudioDeviceCatalog.devices()
            .filter { $0.outputChannels >= AudioWire.speakerChannels }
            .map(\.id)
            .first { Self.standInTransports.contains(transport(of: $0)) }
    }

    private func transport(of device: AudioObjectID) -> UInt32 {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }

    func testTheOutputUnitPullsTheRenderCallbackWhileRunning() throws {
        guard let device = standInOutput() else {
            throw XCTSkip("no USB, built-in or virtual output device on this machine")
        }
        let pulls = AtomicInt(0)
        let output = try XCTUnwrap(PadAudioOutput(device: device, channels: 2) { buffer, frames in
            buffer.update(repeating: 0, count: frames * 2)
            _ = pulls.incrementAndGet()
        })
        XCTAssertTrue(output.start())
        let deadline = Date().addingTimeInterval(2)
        while pulls.get() == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        output.stop()
        XCTAssertGreaterThan(pulls.get(), 0, "the device's IO thread asked for samples")
    }

    func testAnUnknownDeviceCannotBeBound() {
        XCTAssertNil(PadAudioOutput(device: AudioObjectID(0x7FFF_FFFF), channels: 2) { _, _ in })
    }
}
