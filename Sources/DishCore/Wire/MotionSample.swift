// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

/// One IMU reading on the wire's scale: gyro at ±2000 deg/s and accel at
/// ±4 g over int16, right-handed with +X right, +Y up, +Z toward the player.
public struct MotionSample: Equatable, Sendable {
    public var gyroX: Int16
    public var gyroY: Int16
    public var gyroZ: Int16
    public var accelX: Int16
    public var accelY: Int16
    public var accelZ: Int16

    public init(gyroX: Int16, gyroY: Int16, gyroZ: Int16, accelX: Int16, accelY: Int16, accelZ: Int16) {
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
    }
}
