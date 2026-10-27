// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Switch Pro's motion, as dish-android's `sumSwitchImuFrames` and
// `applySwitchProMotion` read it. SDL's default scaling (gyro raw / 14.2842
// deg/s, accel raw / 4096 g), with no factory calibration read, folds into
// the wire's full scales as the divisors below. The axis rotation onto the
// DualShock 4 convention is Android's: pitch and yaw were confirmed on
// hardware there, roll's sign and the accel signs were not.

import Foundation

/// The report packs up to three ~5 ms frames; one 12-byte frame is accel
/// int16 LE x/y/z, then gyro x/y/z, the first at byte 13.
enum SwitchImuLayout {
    static let firstFrame = 13
    static let frameBytes = 12
    static let maxFrames = 3
    static let gyroDivisor: Int64 = 28568
    static let accelDivisor: Int64 = 16384
    static let wireMax: Int64 = 32767
}

/// The frames a report carries, summed per raw axis.
struct SwitchImuSum: Equatable {
    var accelX: Int32 = 0
    var accelY: Int32 = 0
    var accelZ: Int32 = 0
    var gyroX: Int32 = 0
    var gyroY: Int32 = 0
    var gyroZ: Int32 = 0
    var frames: Int32 = 0
}

private func readLe16(_ report: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int32 {
    let low = UInt16(report[offset])
    let high = UInt16(report[offset + 1]) << 8
    return Int32(Int16(bitPattern: low | high))
}

func switchImuFrameCount(length: Int) -> Int {
    guard length >= SwitchImuLayout.firstFrame else { return 0 }
    let available = (length - SwitchImuLayout.firstFrame) / SwitchImuLayout.frameBytes
    return min(available, SwitchImuLayout.maxFrames)
}

func sumSwitchImuFrames(_ report: UnsafeBufferPointer<UInt8>) -> SwitchImuSum {
    var sum = SwitchImuSum()
    let frames = switchImuFrameCount(length: report.count)
    for frame in 0 ..< frames {
        let offset = SwitchImuLayout.firstFrame + SwitchImuLayout.frameBytes * frame
        sum.accelX += readLe16(report, offset)
        sum.accelY += readLe16(report, offset + 2)
        sum.accelZ += readLe16(report, offset + 4)
        sum.gyroX += readLe16(report, offset + 6)
        sum.gyroY += readLe16(report, offset + 8)
        sum.gyroZ += readLe16(report, offset + 10)
    }
    sum.frames = Int32(frames)
    return sum
}

func switchGyroToWire(_ raw: Int16) -> Int16 {
    Int16(clamping: Int64(raw) * SwitchImuLayout.wireMax / SwitchImuLayout.gyroDivisor)
}

func switchAccelToWire(_ raw: Int16) -> Int16 {
    Int16(clamping: Int64(raw) * SwitchImuLayout.wireMax / SwitchImuLayout.accelDivisor)
}

/// The frames' mean, rotated onto the wire: the pad reports pitch, yaw and
/// roll on raw gyro Y, Z and X; pitch and roll are negated. Nil when the
/// report carries no frame.
func switchMotion(_ sum: SwitchImuSum) -> MotionSample? {
    guard sum.frames > 0 else { return nil }
    let count = sum.frames
    return MotionSample(
        gyroX: switchGyroToWire(Int16(clamping: -(sum.gyroY / count))),
        gyroY: switchGyroToWire(Int16(clamping: sum.gyroZ / count)),
        gyroZ: switchGyroToWire(Int16(clamping: -(sum.gyroX / count))),
        accelX: switchAccelToWire(Int16(clamping: sum.accelY / count)),
        accelY: switchAccelToWire(Int16(clamping: sum.accelZ / count)),
        accelZ: switchAccelToWire(Int16(clamping: sum.accelX / count))
    )
}
