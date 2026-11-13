// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The up-direction streams: each one encodes its payload straight into the
/// send's stack buffer through `sendEncrypted`, so no stream builds a `Data`.
extension SatelliteClient {

    // MARK: - Input (hot path)

    /// One `sendto` per report, on the caller's thread, no buffering, in the
    /// shape the SETTLED version decodes: 17 bytes with the extended-buttons
    /// word on version 4 and later, 13 before.
    func sendReport(controllerIndex: Int, report: GamepadReport) {
        let settled = settledProtocolVersion
        let payloadCount = ProtocolConstants.inputPayloadBytes(settledVersion: settled)
        sendEncrypted(msgType: ProtocolConstants.msgInput, payloadCount: payloadCount) { out in
            Encoders.writeInputPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                report: report,
                settledVersion: settled,
                into: out
            )
        }
    }

    // MARK: - Motion (IMU)

    func sendMotion(controllerIndex: Int, sample: MotionSample, timestampDeltaUs: UInt32) {
        sendEncrypted(msgType: ProtocolConstants.msgMotion, payloadCount: ProtocolConstants.motionPayloadBytes) { out in
            Encoders.writeMotionPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                sample: sample,
                timestampDeltaUs: timestampDeltaUs,
                into: out
            )
        }
    }

    // MARK: - Battery

    /// Forward a battery snapshot (MSG_BATTERY 0x000B). `level` is 0...100,
    /// or `ProtocolConstants.batteryLevelUnknown` (0xFF) for status-only
    /// readers; senders with no battery information at all MUST NOT call.
    /// The main actor sends it too, through the same gate as the pads.
    func sendBattery(controllerIndex: Int, level: UInt8, status: BatteryStatus) {
        sendEncrypted(msgType: ProtocolConstants.msgBattery, payloadCount: ProtocolConstants.batteryPayloadBytes) { out in
            Encoders.writeBatteryPayload(
                controllerIndex: UInt8(truncatingIfNeeded: controllerIndex),
                level: level,
                status: status,
                into: out
            )
        }
    }

    // MARK: - Touchpad

    /// Forward a touchpad sample (MSG_TOUCHPAD 0x000C) in the shape the
    /// SETTLED version decodes: the 19-byte POINTER frame on version 2 and
    /// later, the 16-byte frame on version 1, which drops anything longer.
    /// Coordinates are normalised int16; the caller scales. Hot path:
    /// GameController touchpad callback thread.
    func sendTouchpad(controllerIndex: Int, sample: TouchpadSample, eventTimeMs: UInt32) {
        let index = UInt8(truncatingIfNeeded: controllerIndex)
        if ProtocolConstants.settledSpeaksV2(settledProtocolVersion) {
            sendEncrypted(msgType: ProtocolConstants.msgTouchpad, payloadCount: 1 + ProtocolConstants.pointerPayloadBytes) { out in
                Encoders.writePointerPayload(controllerIndex: index, sample: sample, eventTimeMs: eventTimeMs, into: out)
            }
        } else {
            sendEncrypted(msgType: ProtocolConstants.msgTouchpad, payloadCount: 1 + ProtocolConstants.touchpadPayloadBytes) { out in
                Encoders.writeTouchpadPayload(controllerIndex: index, sample: sample, eventTimeMs: eventTimeMs, into: out)
            }
        }
    }

    // MARK: - Microphone

    /// One 20 ms Opus packet from the pad's microphone (MSG_MIC_AUDIO 0x0012).
    /// The caller enforces mute: a muted client calls this not at all.
    func sendMicAudio(_ frame: AudioFrame) {
        sendEncrypted(msgType: ProtocolConstants.msgMicAudio, payloadCount: frame.payloadCount) { out in
            frame.writePayload(into: out)
        }
    }
}
