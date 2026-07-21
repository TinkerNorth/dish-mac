// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Semantic coverage for the GCMotion → MSG_MOTION wire mapping and the
/// GameController-touchpad → MSG_TOUCHPAD wire mapping.
///
/// The pre-existing `MotionBatteryProcessorTests` feed *already-scaled* ints
/// into `publishMotion`, so they never exercise the GCMotion-frame conversion
/// — a wrong accel sign or a swapped axis was invisible to them. These tests
/// drive the pure conversion functions (`gcMotionToWire`, `gcTouchpadAxisToWire`,
/// `nextTouchpadTrackingId`) with `GCMotion`-shaped inputs (rad/s gyro, g
/// gravity+userAccel) and assert the wire output's axis, sign, and scale.
///
/// The wire contract under test (satellite/docs/contract.md, core/types.h):
///   * gyro: deg/s, scale 2000/32767, right-handed +X right / +Y up / +Z
///     toward player.
///   * accel: g, scale 4/32767, same frame; the wire wants *specific force*
///     (proper acceleration) — ≈ +1 g on the up axis at rest.
///   * touchpad: centre-origin int16, +x right, +y DOWN.
final class MotionConversionTests: XCTestCase {

    /// Tolerance for one int16 LSB of integer-rounding slack in the scalers.
    private let lsb: Int16 = 1

    private func assertNear(_ value: Int16, _ expected: Int16, _ msg: String = "") {
        XCTAssertLessThanOrEqual(abs(Int(value) - Int(expected)), Int(lsb), msg)
    }

    // Wire LSB sizes derived from the protocol scale constants.
    // gyro:  2000 deg/s → 32767  ⇒ ≈ 16.38 LSB per deg/s.
    private let gyroLsbPerDegPerSec = 32767.0 / 2000.0
    // accel: 4 g → 32767          ⇒ ≈ 8191.75 LSB per g.
    private let accelLsbPerG = 32767.0 / 4.0

    // MARK: - Accel: the specific-force formula (review item C2)

    /// Reference point 1 — controller at rest, screen up (+Y up). GCMotion
    /// reports `userAcceleration` ≈ 0 and `gravity` ≈ (0, -1, 0) (the load
    /// vector points toward the ground). The wire must read ≈ +1 g on +Y.
    func testAccelAtRestScreenUpReadsPlusOneGUp() {
        let wire = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: -1,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        assertNear(wire.accelX, 0, "X must be ~0 at rest")
        assertNear(wire.accelY, Int16(accelLsbPerG.rounded()), "Y must be ~+1 g (specific force up)")
        assertNear(wire.accelZ, 0, "Z must be ~0 at rest")
    }

    /// Reference point 2 — accelerating straight up at 1 g. GCMotion reports
    /// `userAcceleration` = (0, +1, 0) on top of `gravity` = (0, -1, 0). The
    /// wire must read ≈ +2 g up. Only `userAccel - gravity` satisfies BOTH
    /// this and the at-rest case; `-(gravity + userAccel)` reads 0 here.
    func testAccelAcceleratingUpAtOneGReadsPlusTwoGUp() {
        let wire = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: -1,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 1,
            userAccelZ: 0
        )
        assertNear(
            wire.accelY,
            Int16((2.0 * accelLsbPerG).rounded()),
            "Y must be ~+2 g — gravity-up (+1 g) plus 1 g of upward thrust"
        )
    }

    /// A sideways thrust while at rest: gravity load on -Y, user thrust of
    /// +0.5 g on +X. The wire must carry the thrust on X (+0.5 g) AND the
    /// gravity-up term on Y (+1 g) — the gravity decomposition must not eat
    /// the linear-acceleration term, which is exactly the C2 bug.
    func testAccelLinearTermSurvivesGravityDecomposition() {
        let wire = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: -1,
            gravityZ: 0,
            userAccelX: 0.5,
            userAccelY: 0,
            userAccelZ: 0
        )
        assertNear(wire.accelX, Int16((0.5 * accelLsbPerG).rounded()), "X must carry the +0.5 g thrust")
        assertNear(wire.accelY, Int16(accelLsbPerG.rounded()), "Y must still read +1 g up")
    }

    /// Per-axis: gravity on each axis maps to that same wire axis with the
    /// sign flipped (load → specific force), no axis swap.
    func testAccelGravityMapsPerAxisWithSignFlip() {
        // Gravity purely on +X (controller on its side) → wire accelX ≈ -1 g
        // (specific force points opposite the gravity load).
        let onX = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 1,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        assertNear(onX.accelX, Int16((-accelLsbPerG).rounded()))
        assertNear(onX.accelY, 0)
        assertNear(onX.accelZ, 0)

        // Gravity purely on -Z → wire accelZ ≈ +1 g.
        let onZ = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: -1,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        assertNear(onZ.accelZ, Int16(accelLsbPerG.rounded()))
        assertNear(onZ.accelX, 0)
        assertNear(onZ.accelY, 0)
    }

    func testAccelClampsBeyondFourG() {
        let wire = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: -10,
            gravityY: 10,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        XCTAssertEqual(wire.accelX, Int16.max) // -(-10) = +10 g → clamp +max
        XCTAssertEqual(wire.accelY, Int16.min) // -(10) = -10 g → clamp -min
    }

    // MARK: - Gyro: rad/s → deg/s, frame mapping (review item C1)

    func testGyroZeroIsZero() {
        let wire = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        XCTAssertEqual(wire.gyroX, 0)
        XCTAssertEqual(wire.gyroY, 0)
        XCTAssertEqual(wire.gyroZ, 0)
    }

    /// GCMotion's `rotationRate` is rad/s; the wire is deg/s. A rotation of
    /// π rad/s is exactly 180 deg/s — assert the conversion + scale per axis,
    /// with no axis swap (X→X, Y→Y, Z→Z) and sign preserved.
    func testGyroRadiansToDegreesPerAxis() {
        let halfPi = Double.pi / 2.0 // 90 deg/s
        let wire = gcMotionToWire(
            rotationRateRadX: halfPi,
            rotationRateRadY: -halfPi,
            rotationRateRadZ: Double.pi,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        assertNear(wire.gyroX, Int16((90.0 * gyroLsbPerDegPerSec).rounded()), "X: +π/2 rad/s → +90 deg/s")
        assertNear(wire.gyroY, Int16((-90.0 * gyroLsbPerDegPerSec).rounded()), "Y: -π/2 rad/s → -90 deg/s")
        assertNear(wire.gyroZ, Int16((180.0 * gyroLsbPerDegPerSec).rounded()), "Z: +π rad/s → +180 deg/s")
    }

    /// Full-scale: 2000 deg/s is the wire's ±32767 limit. 2000 deg/s in rad/s
    /// is 2000 * π/180.
    func testGyroFullScaleHitsInt16Limit() {
        let twoThousandDegInRad = 2000.0 * Double.pi / 180.0
        let wire = gcMotionToWire(
            rotationRateRadX: twoThousandDegInRad,
            rotationRateRadY: -twoThousandDegInRad,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        assertNear(wire.gyroX, Int16.max)
        assertNear(wire.gyroY, Int16.min)
    }

    func testGyroClampsBeyondTwoThousandDegPerSec() {
        let fourThousandDegInRad = 4000.0 * Double.pi / 180.0
        let wire = gcMotionToWire(
            rotationRateRadX: fourThousandDegInRad,
            rotationRateRadY: -fourThousandDegInRad,
            rotationRateRadZ: 0,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        XCTAssertEqual(wire.gyroX, Int16.max)
        XCTAssertEqual(wire.gyroY, Int16.min)
    }

    /// Gyro and accel are independent surfaces — a pure rotation must not
    /// leak into the accel axes and vice versa.
    func testGyroAndAccelDoNotCrossContaminate() {
        let pureSpin = gcMotionToWire(
            rotationRateRadX: 1,
            rotationRateRadY: 2,
            rotationRateRadZ: 3,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        XCTAssertEqual(pureSpin.accelX, 0)
        XCTAssertEqual(pureSpin.accelY, 0)
        XCTAssertEqual(pureSpin.accelZ, 0)

        let pureAccel = gcMotionToWire(
            rotationRateRadX: 0,
            rotationRateRadY: 0,
            rotationRateRadZ: 0,
            gravityX: 1,
            gravityY: 0,
            gravityZ: 0,
            userAccelX: 0,
            userAccelY: 0,
            userAccelZ: 0
        )
        XCTAssertEqual(pureAccel.gyroX, 0)
        XCTAssertEqual(pureAccel.gyroY, 0)
        XCTAssertEqual(pureAccel.gyroZ, 0)
    }

    // MARK: - Touchpad: centre-origin, +y DOWN (review item #4)

    /// GameController's touchpad axes are centre-origin `-1..1` with `+y` UP;
    /// the wire is centre-origin int16 with `+y` DOWN. `gcTouchpadAxisToWire`
    /// scales by 32767 and negates y.
    func testTouchpadXMapsStraightThrough() {
        let right = gcTouchpadAxisToWire(x: 1.0, y: 0.0)
        assertNear(right.x, 32767, "+x (right) → +32767")
        let left = gcTouchpadAxisToWire(x: -1.0, y: 0.0)
        assertNear(left.x, -32767, "-x (left) → -32767")
    }

    func testTouchpadYIsNegatedSoPlusIsDown() {
        // GameController +y is UP. The wire's +y is DOWN, so a finger at the
        // TOP of the pad (GC y = +1) must encode as a NEGATIVE wire y.
        let topOfPad = gcTouchpadAxisToWire(x: 0.0, y: 1.0)
        assertNear(topOfPad.y, -32767, "GC +y (top) must negate to wire -y")
        // A finger at the BOTTOM (GC y = -1) → positive wire y.
        let bottomOfPad = gcTouchpadAxisToWire(x: 0.0, y: -1.0)
        assertNear(bottomOfPad.y, 32767, "GC -y (bottom) must negate to wire +y")
    }

    func testTouchpadCentreIsZero() {
        let centre = gcTouchpadAxisToWire(x: 0.0, y: 0.0)
        XCTAssertEqual(centre.x, 0)
        XCTAssertEqual(centre.y, 0)
    }

    func testTouchpadOffCentreSign() {
        // Top-right quadrant: GC (+x, +y) → wire (+x, -y).
        let topRight = gcTouchpadAxisToWire(x: 0.5, y: 0.5)
        XCTAssertGreaterThan(topRight.x, 0)
        XCTAssertLessThan(topRight.y, 0)
    }

    // MARK: - Touchpad tracking ids (review item M3)

    /// A finger's id bumps only on a false → true (fresh-contact) edge.
    func testTrackingIdBumpsOnFreshContact() {
        // Idle → idle: no bump.
        XCTAssertEqual(nextTouchpadTrackingId(wasActive: false, isActive: false, current: 5), 5)
        // Idle → touch: bump.
        XCTAssertEqual(nextTouchpadTrackingId(wasActive: false, isActive: true, current: 5), 6)
        // Touch held: no bump.
        XCTAssertEqual(nextTouchpadTrackingId(wasActive: true, isActive: true, current: 6), 6)
        // Lift: no bump.
        XCTAssertEqual(nextTouchpadTrackingId(wasActive: true, isActive: false, current: 6), 6)
    }

    /// A full press → drag → lift → re-press cycle yields exactly two ids.
    func testTrackingIdAcrossContactCycle() {
        var id: UInt8 = 0
        var wasActive = false
        // First touch-down.
        id = nextTouchpadTrackingId(wasActive: wasActive, isActive: true, current: id)
        wasActive = true
        XCTAssertEqual(id, 1)
        // Drag (held).
        id = nextTouchpadTrackingId(wasActive: wasActive, isActive: true, current: id)
        XCTAssertEqual(id, 1)
        // Lift.
        id = nextTouchpadTrackingId(wasActive: wasActive, isActive: false, current: id)
        wasActive = false
        XCTAssertEqual(id, 1)
        // Second touch-down — a NEW contact, new id.
        id = nextTouchpadTrackingId(wasActive: wasActive, isActive: true, current: id)
        wasActive = true
        XCTAssertEqual(id, 2)
    }

    /// `UInt8` wraps freely — the protocol says ids "wrap freely".
    func testTrackingIdWrapsAt255() {
        XCTAssertEqual(nextTouchpadTrackingId(wasActive: false, isActive: true, current: 255), 0)
    }

    // MARK: - TouchpadTrackingState (the lock-guarded per-device holder)

    func testTrackingStateIsPerFingerAndPerDevice() {
        let state = TouchpadTrackingState()
        // padA: finger0 touches, finger1 idle.
        var ids = state.advance(deviceId: "padA", finger0Active: true, finger1Active: false)
        XCTAssertEqual(ids.finger0, 1)
        XCTAssertEqual(ids.finger1, 0)
        // padA: finger0 still held (no bump), finger1 now touches (bump).
        ids = state.advance(deviceId: "padA", finger0Active: true, finger1Active: true)
        XCTAssertEqual(ids.finger0, 1)
        XCTAssertEqual(ids.finger1, 1)
        // padB is independent — its first contact starts at id 1.
        let other = state.advance(deviceId: "padB", finger0Active: true, finger1Active: false)
        XCTAssertEqual(other.finger0, 1)
    }

    func testTrackingStateRemoveResetsDevice() {
        let state = TouchpadTrackingState()
        _ = state.advance(deviceId: "pad", finger0Active: true, finger1Active: false)
        _ = state.advance(deviceId: "pad", finger0Active: false, finger1Active: false)
        _ = state.advance(deviceId: "pad", finger0Active: true, finger1Active: false) // id now 2
        state.remove(deviceId: "pad")
        // Re-added device starts fresh — first contact is id 1, not a stale 3.
        let ids = state.advance(deviceId: "pad", finger0Active: true, finger1Active: false)
        XCTAssertEqual(ids.finger0, 1)
    }
}
