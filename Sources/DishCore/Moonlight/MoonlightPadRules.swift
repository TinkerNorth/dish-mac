// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What a CONTROLLER_ARRIVAL declares, and when a held pad has to be plugged
// again. The capability table is client-side knowledge: no host reports what
// its emulated pads can do; it builds them from the type and the bits this
// client declares, and reads only the motion bits at arrival (Wolf's
// create_new_joypad). The rules are dish-android's, the reference client.

import Foundation

/// What the local pad can actually feed or actuate; analog triggers always.
public struct MoonlightSourceCapabilities: Equatable, Sendable {
    public var rumble = false
    public var triggerRumble = false
    public var motion = false
    public var touchpad = false
    public var battery = false
    public var lightbar = false

    public init(
        rumble: Bool = false,
        triggerRumble: Bool = false,
        motion: Bool = false,
        touchpad: Bool = false,
        battery: Bool = false,
        lightbar: Bool = false
    ) {
        self.rumble = rumble
        self.triggerRumble = triggerRumble
        self.motion = motion
        self.touchpad = touchpad
        self.battery = battery
        self.lightbar = lightbar
    }
}

/// What one arrival tells the host a pad is. The announcement and anything
/// that shows the binding read this one computation.
public struct MoonlightAnnouncedPad: Equatable, Sendable {
    public var type: UInt8
    public var capabilities: UInt8
    public var supportedButtons: UInt32

    public init(type: UInt8, capabilities: UInt8, supportedButtons: UInt32) {
        self.type = type
        self.capabilities = capabilities
        self.supportedButtons = supportedButtons
    }
}

/// What converging one requested pad does with the pad its slot already holds.
public enum MoonlightPadPlacement: Equatable, Sendable {
    case acquire
    case keep
    /// A replug: unplug, then a fresh arrival. It unplugs the pad in the game,
    /// so only a change the host reads is worth one.
    case reannounce
}

public enum MoonlightPadRules {
    /// The bits a host reads when a pad arrives, and at no other time.
    public static let capsReadAtArrival: UInt8 = MoonlightCapability.accelerometer | MoonlightCapability.gyro
    /// XUSB's low sixteen less the satellite's mic-mute bit, which is no Moonlight button.
    public static let baseButtons: UInt32 = 0xFFFF & ~MoonlightButton.reservedMicMute
    /// What a frame may carry: the base set and the touchpad click.
    public static let frameButtonMask: UInt32 = baseButtons | MoonlightButton.touchpad
    /// Trigger rumble and battery describe the physical pad, so every type
    /// carries them; only a PlayStation pad gets motion, a touchpad and a lamp.
    public static let baseCeiling: UInt8 = MoonlightCapability.analogTriggers | MoonlightCapability.rumble
        | MoonlightCapability.triggerRumble | MoonlightCapability.battery
    public static let playStationCeiling: UInt8 = 0xFF

    public static func sourceBits(_ source: MoonlightSourceCapabilities) -> UInt8 {
        var bits = MoonlightCapability.analogTriggers
        if source.rumble { bits |= MoonlightCapability.rumble }
        if source.triggerRumble { bits |= MoonlightCapability.triggerRumble }
        if source.motion { bits |= MoonlightCapability.accelerometer | MoonlightCapability.gyro }
        if source.touchpad { bits |= MoonlightCapability.touchpad }
        if source.battery { bits |= MoonlightCapability.battery }
        if source.lightbar { bits |= MoonlightCapability.rgbLed }
        return bits
    }

    public static func typeCeiling(_ type: UInt8) -> UInt8 {
        type == MoonlightControllerType.playStation ? playStationCeiling : baseCeiling
    }

    /// Auto resolves on the client, before the wire: a pad with motion
    /// becomes PlayStation, the only type the host wires motion into.
    public static func resolveType(picked: UInt8, sourceHasMotion: Bool) -> UInt8 {
        guard picked == MoonlightControllerType.auto else { return picked }
        return sourceHasMotion ? MoonlightControllerType.playStation : MoonlightControllerType.xbox
    }

    /// A stored pick, normalised: a record from before the sentinel holds 0
    /// for Auto, which is the wire's Unknown, so it and anything else outside
    /// the picker's range read as Auto.
    public static func migrateStoredType(_ stored: Int) -> UInt8 {
        switch stored {
        case Int(MoonlightControllerType.xbox), Int(MoonlightControllerType.playStation), Int(MoonlightControllerType.nintendo):
            UInt8(stored)
        default:
            MoonlightControllerType.auto
        }
    }

    public static func supportedButtons(capabilities: UInt8) -> UInt32 {
        capabilities & MoonlightCapability.touchpad != 0 ? baseButtons | MoonlightButton.touchpad : baseButtons
    }

    /// The type's ceiling intersected with what the source can deliver, and
    /// the buttons that follow from it.
    public static func arrival(storedType: Int, source: MoonlightSourceCapabilities) -> MoonlightAnnouncedPad {
        let type = resolveType(picked: migrateStoredType(storedType), sourceHasMotion: source.motion)
        let capabilities = typeCeiling(type) & sourceBits(source)
        return MoonlightAnnouncedPad(type: type, capabilities: capabilities, supportedButtons: supportedButtons(capabilities: capabilities))
    }

    public static func placement(held: MoonlightAnnouncedPad?, wanted: MoonlightAnnouncedPad) -> MoonlightPadPlacement {
        guard let held else { return .acquire }
        if held.type != wanted.type { return .reannounce }
        if (held.capabilities ^ wanted.capabilities) & capsReadAtArrival != 0 { return .reannounce }
        return .keep
    }

    /// Whether a pad's touches reach the host: the pad pick on a type whose
    /// pad has a touchpad; a Mouse pick puts no touches on the pad.
    public static func touchReachesHost(pick: TouchpadPick, padHasTouchpad: Bool, type: UInt8) -> Bool {
        let typeRendersPad = typeCeiling(type) & MoonlightCapability.touchpad != 0
        return resolveTouchpadMode(pick: pick, padHasTouchpad: padHasTouchpad, typeOffersDs4: typeRendersPad, hostMouseControl: false) ==
            .ds4
    }
}
