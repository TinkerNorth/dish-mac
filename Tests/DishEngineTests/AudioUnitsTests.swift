// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreAudio
import XCTest
@testable import DishEngine

/// The output edge binds to a device and runs; with no pad attached the
/// default output stands in, rendering silence. The input edge is never
/// bound here: touching a microphone device asks the system for permission,
/// which no test can answer.
final class AudioUnitsTests: XCTestCase {

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var property = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    func testTheOutputUnitPullsTheRenderCallbackWhileRunning() throws {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            throw XCTSkip("no default output device on this machine")
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
