// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A generic HID pad's per-model remap, in the desktops' `JoystickRemap`
// shape (`JoystickMapping.h`): which raw source drives each wire control.
// On the Mac a raw source is what the descriptor declared: a button by its
// declared index, the d-pad by hat 0 (the hat, or the three-state axes the
// pad declares instead), and an axis by its slot in DirectInput's order,
// X Y Z(lt) Rx Ry Rz(rt) read as lx ly lt rx ry rt, so the desktops' default
// axes (0 1 3 4, triggers 2 5) are the Mac's own decode. Guide is the one
// control the desktops' table lacks; it rides an extra field they ignore.

import Foundation

/// A trigger is an analog axis or a digital button.
public enum TriggerSourceKind: Equatable, Sendable {
    case axis
    case button
}

public struct TriggerSource: Equatable, Sendable {
    public var kind: TriggerSourceKind
    /// -1 is unassigned: the trigger reads 0.
    public var index: Int

    public init(kind: TriggerSourceKind, index: Int) {
        self.kind = kind
        self.index = index
    }
}

/// The desktops' `RemapButton` order: the persisted `btn` array is indexed by it.
public enum RemapButton: Int, CaseIterable, Sendable {
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case start
    case back
    case leftThumb
    case rightThumb
    case leftShoulder
    case rightShoulder
    case faceA
    case faceB
    case faceX
    case faceY

    public var wire: WireButton {
        switch self {
        case .dpadUp: .dpadUp
        case .dpadDown: .dpadDown
        case .dpadLeft: .dpadLeft
        case .dpadRight: .dpadRight
        case .start: .start
        case .back: .back
        case .leftThumb: .leftThumb
        case .rightThumb: .rightThumb
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .faceA: .faceA
        case .faceB: .faceB
        case .faceX: .faceX
        case .faceY: .faceY
        }
    }
}

public enum RemapAxis {
    public static let leftX = 0
    public static let leftY = 1
    public static let leftTrigger = 2
    public static let rightX = 3
    public static let rightY = 4
    public static let rightTrigger = 5
    public static let count = 6
}

public enum RemapDefaults {
    public static let unassigned = -1
    /// The one d-pad source a HID pad has.
    public static let hat = 0
    /// The desktops' default face-first DirectInput order, by `RemapButton`.
    static let desktopButtons = [-1, -1, -1, -1, 7, 6, 10, 11, 4, 5, 0, 1, 2, 3]
}

/// Indices are raw sources; -1 is unassigned and reads neutral. The
/// defaults are the desktops' `JoystickRemap{}` verbatim.
public struct JoystickRemap: Equatable, Sendable {
    public var leftStickX = RemapAxis.leftX
    public var leftStickY = RemapAxis.leftY
    public var rightStickX = RemapAxis.rightX
    public var rightStickY = RemapAxis.rightY
    /// HID's Y is down-positive and the wire's up-positive, so on means the
    /// axis is negated on its way to the wire.
    public var invertLeftY = true
    public var invertRightY = true
    public var leftTrigger = TriggerSource(kind: .axis, index: RemapAxis.leftTrigger)
    public var rightTrigger = TriggerSource(kind: .axis, index: RemapAxis.rightTrigger)
    /// One raw button per `RemapButton`.
    public var buttons = RemapDefaults.desktopButtons
    public var hatIndex = RemapDefaults.hat
    /// Kept for the desktops, which read them; the Mac reads its axes by usage.
    public var useAdaptiveRightStick = true
    public var useAdaptiveTriggers = true
    /// The Mac's extra: the raw button that is Guide.
    public var guide = RemapDefaults.unassigned

    public init() {}

    public func button(_ which: RemapButton) -> Int {
        buttons[which.rawValue]
    }

    public mutating func setButton(_ which: RemapButton, _ index: Int) {
        buttons[which.rawValue] = index
    }
}

/// The remap that reads a pad exactly as its model's button order does, so
/// a walk that starts from nothing stored changes only what it assigns.
public func defaultRemap(order: HidButtonOrder) -> JoystickRemap {
    let map = buttonOrderMap(order)
    var remap = JoystickRemap()
    for which in RemapButton.allCases {
        remap.setButton(which, declaredIndex(of: which.wire, in: map))
    }
    remap.guide = declaredIndex(of: .guide, in: map)
    if let triggers = map.triggers {
        remap.leftTrigger = TriggerSource(kind: .button, index: triggers.left)
        remap.rightTrigger = TriggerSource(kind: .button, index: triggers.right)
    }
    return remap
}

/// The first declared index the map puts on `wire`; the d-pad is the hat's.
private func declaredIndex(of wire: WireButton, in map: HidButtonOrderMap) -> Int {
    map.buttons.firstIndex { $0 == wire } ?? RemapDefaults.unassigned
}

// MARK: - The stored shape

/// The desktops' compact field names, so one `joystick_remaps` blob reads
/// the same on every client.
public enum RemapField {
    public static let key = "vk"
    static let leftStickX = "lsx"
    static let leftStickY = "lsy"
    static let rightStickX = "rsx"
    static let rightStickY = "rsy"
    static let invertLeftY = "ily"
    static let invertRightY = "iry"
    static let leftTriggerKind = "ltk"
    static let leftTriggerIndex = "lti"
    static let rightTriggerKind = "rtk"
    static let rightTriggerIndex = "rti"
    static let buttons = "btn"
    static let hat = "hat"
    static let adaptiveRightStick = "ars"
    static let adaptiveTriggers = "atr"
    static let guide = "gd"
    /// The trigger kind's stored integer: 0 an axis, 1 a button.
    static let buttonKind = 1
    static let axisKind = 0
}

/// Every field, as `joystickRemapToJson` writes them.
public func remapFields(_ remap: JoystickRemap) -> [String: Any] {
    [
        RemapField.leftStickX: remap.leftStickX,
        RemapField.leftStickY: remap.leftStickY,
        RemapField.rightStickX: remap.rightStickX,
        RemapField.rightStickY: remap.rightStickY,
        RemapField.invertLeftY: remap.invertLeftY,
        RemapField.invertRightY: remap.invertRightY,
        RemapField.leftTriggerKind: triggerKindNumber(remap.leftTrigger.kind),
        RemapField.leftTriggerIndex: remap.leftTrigger.index,
        RemapField.rightTriggerKind: triggerKindNumber(remap.rightTrigger.kind),
        RemapField.rightTriggerIndex: remap.rightTrigger.index,
        RemapField.buttons: remap.buttons,
        RemapField.hat: remap.hatIndex,
        RemapField.adaptiveRightStick: remap.useAdaptiveRightStick,
        RemapField.adaptiveTriggers: remap.useAdaptiveTriggers,
        RemapField.guide: remap.guide
    ]
}

/// Each field read on its own over the default, as `joystickRemapFromJson`
/// does: a missing or garbled field keeps its default, and a button array
/// of the wrong length is ignored whole.
public func remap(fields: [String: Any]) -> JoystickRemap {
    var remap = JoystickRemap()
    remap.leftStickX = intField(fields, RemapField.leftStickX) ?? remap.leftStickX
    remap.leftStickY = intField(fields, RemapField.leftStickY) ?? remap.leftStickY
    remap.rightStickX = intField(fields, RemapField.rightStickX) ?? remap.rightStickX
    remap.rightStickY = intField(fields, RemapField.rightStickY) ?? remap.rightStickY
    remap.invertLeftY = boolField(fields, RemapField.invertLeftY) ?? remap.invertLeftY
    remap.invertRightY = boolField(fields, RemapField.invertRightY) ?? remap.invertRightY
    remap.leftTrigger = triggerField(fields, kind: RemapField.leftTriggerKind, index: RemapField.leftTriggerIndex, remap.leftTrigger)
    remap.rightTrigger = triggerField(fields, kind: RemapField.rightTriggerKind, index: RemapField.rightTriggerIndex, remap.rightTrigger)
    remap.hatIndex = intField(fields, RemapField.hat) ?? remap.hatIndex
    remap.useAdaptiveRightStick = boolField(fields, RemapField.adaptiveRightStick) ?? remap.useAdaptiveRightStick
    remap.useAdaptiveTriggers = boolField(fields, RemapField.adaptiveTriggers) ?? remap.useAdaptiveTriggers
    remap.guide = intField(fields, RemapField.guide) ?? remap.guide
    remap.buttons = buttonsField(fields) ?? remap.buttons
    return remap
}

private func triggerKindNumber(_ kind: TriggerSourceKind) -> Int {
    switch kind {
    case .axis: RemapField.axisKind
    case .button: RemapField.buttonKind
    }
}

/// A number is an integer whatever its stored width; a Boolean is not one.
private func intField(_ fields: [String: Any], _ name: String) -> Int? {
    fields[name].flatMap(integer)
}

private func boolField(_ fields: [String: Any], _ name: String) -> Bool? {
    guard let number = fields[name] as? NSNumber, isBoolean(number) else { return nil }
    return number.boolValue
}

private func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func triggerField(_ fields: [String: Any], kind: String, index: String, _ fallback: TriggerSource) -> TriggerSource {
    let storedKind = intField(fields, kind).map { $0 == RemapField.buttonKind ? TriggerSourceKind.button : .axis }
    return TriggerSource(kind: storedKind ?? fallback.kind, index: intField(fields, index) ?? fallback.index)
}

private func buttonsField(_ fields: [String: Any]) -> [Int]? {
    guard let stored = fields[RemapField.buttons] as? [Any], stored.count == RemapButton.allCases.count else { return nil }
    let defaults = RemapDefaults.desktopButtons
    return stored.enumerated().map { index, value in integer(value) ?? defaults[index] }
}

private func integer(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
    return number.intValue
}
