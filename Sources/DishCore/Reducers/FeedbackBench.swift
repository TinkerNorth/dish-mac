// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Diagnostics bench's test buzz: which motors run, how hard and for how
// long, the same strength and time as dish-android's inspector, so a pad
// feels the same test on either client. Rumble is the one feedback surface
// the bench drives, because it is transient by nature: a light bar colour,
// the player LEDs, a trigger effect and the mute lamp are state the host
// set, and a test would overwrite it with nothing to put it back.

import Foundation

public enum BuzzMotor: CaseIterable, Equatable, Sendable {
    case weak
    case strong
    case both
}

public struct TestBuzz: Equatable, Sendable {
    public var strong: UInt16
    public var weak: UInt16
    public var durationMs: UInt16

    public init(strong: UInt16, weak: UInt16, durationMs: UInt16) {
        self.strong = strong
        self.weak = weak
        self.durationMs = durationMs
    }

    public static let magnitude: UInt16 = 48000
    public static let durationMs: UInt16 = 400
}

public func testBuzz(for motor: BuzzMotor) -> TestBuzz {
    switch motor {
    case .weak: TestBuzz(strong: 0, weak: TestBuzz.magnitude, durationMs: TestBuzz.durationMs)
    case .strong: TestBuzz(strong: TestBuzz.magnitude, weak: 0, durationMs: TestBuzz.durationMs)
    case .both: TestBuzz(strong: TestBuzz.magnitude, weak: TestBuzz.magnitude, durationMs: TestBuzz.durationMs)
    }
}
