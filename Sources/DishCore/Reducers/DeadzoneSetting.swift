// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A pad's dead zones as the Dead zones page and the store keep them: the
// flats on the wire's scales (int16 stick, 0...255 trigger), the slider's
// percentages over those ranges, and the desktops' stored shape under
// `deadzone:<slotId>`, `{"s":…,"t":…}`.

import Foundation

public struct DeadzoneSetting: Equatable, Sendable {
    public let stickFlat: Int16
    public let triggerFlat: UInt8

    public static let stickRange = 32767
    public static let triggerRange = 255
    /// The sliders' travel, as on the desktops.
    public static let maxPercent = 30
    /// About 10 % of the stick range and 5 % of the trigger range: a noise
    /// floor that keeps a cheap pad from twitching at rest without clipping
    /// deliberate small inputs.
    public static let defaults = DeadzoneSetting(stickFlat: 3277, triggerFlat: 13)

    private static let stickKey = "s"
    private static let triggerKey = "t"

    public init(stickFlat: Int16, triggerFlat: UInt8) {
        self.stickFlat = stickFlat
        self.triggerFlat = triggerFlat
    }

    /// The slider's percentages, clamped to the travel.
    public init(stickPercent: Int, triggerPercent: Int) {
        let stick = rawFromPercent(stickPercent, range: Self.stickRange)
        let trigger = rawFromPercent(triggerPercent, range: Self.triggerRange)
        self.init(stickFlat: Int16(clamping: stick), triggerFlat: UInt8(clamping: trigger))
    }

    /// The stored shape; nil when nothing reads.
    public init?(storedJson: String?) {
        guard let storedJson,
              let object = try? JSONSerialization.jsonObject(with: Data(storedJson.utf8)) as? [String: Any],
              let stick = object[Self.stickKey] as? Int,
              let trigger = object[Self.triggerKey] as? Int else { return nil }
        self.init(stickFlat: Int16(clamping: stick), triggerFlat: UInt8(clamping: trigger))
    }

    public var stickPercent: Int {
        percentOf(Int(stickFlat), range: Self.stickRange)
    }

    public var triggerPercent: Int {
        percentOf(Int(triggerFlat), range: Self.triggerRange)
    }

    public func withStickPercent(_ percent: Int) -> DeadzoneSetting {
        DeadzoneSetting(stickPercent: percent, triggerPercent: triggerPercent)
            .keepingTrigger(triggerFlat)
    }

    public func withTriggerPercent(_ percent: Int) -> DeadzoneSetting {
        DeadzoneSetting(stickPercent: stickPercent, triggerPercent: percent)
            .keepingStick(stickFlat)
    }

    public var storedJson: String {
        "{\"\(Self.stickKey)\":\(stickFlat),\"\(Self.triggerKey)\":\(triggerFlat)}"
    }

    private func keepingTrigger(_ flat: UInt8) -> DeadzoneSetting {
        DeadzoneSetting(stickFlat: stickFlat, triggerFlat: flat)
    }

    private func keepingStick(_ flat: Int16) -> DeadzoneSetting {
        DeadzoneSetting(stickFlat: flat, triggerFlat: triggerFlat)
    }
}

private func rawFromPercent(_ percent: Int, range: Int) -> Int {
    let clamped = min(max(percent, 0), DeadzoneSetting.maxPercent)
    let share = Double(clamped) / 100
    return Int((share * Double(range)).rounded())
}

private func percentOf(_ raw: Int, range: Int) -> Int {
    let share = Double(raw) / Double(range)
    return Int((share * 100).rounded())
}
