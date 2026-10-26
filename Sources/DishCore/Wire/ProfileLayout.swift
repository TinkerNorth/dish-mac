// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

/// Which half of the pad an axis or a trigger belongs to.
public enum PadSide: Equatable, Sendable {
    case left
    case right
}

/// One of the N64's four C buttons, which rail the right stick.
public enum CButton: CaseIterable, Equatable, Sendable {
    case up
    case down
    case left
    case right

    var bit: UInt8 {
        switch self {
        case .up: 0x01
        case .down: 0x02
        case .left: 0x04
        case .right: 0x08
        }
    }
}

/// The C buttons held down, one bit each, so a sample never builds a set.
public struct CButtonWord: Equatable, Sendable, ExpressibleByArrayLiteral {
    public private(set) var rawValue: UInt8

    public init() {
        rawValue = 0
    }

    public init(arrayLiteral buttons: CButton...) {
        rawValue = buttons.reduce(UInt8(0)) { word, button in word | button.bit }
    }

    public mutating func insert(_ button: CButton) {
        rawValue |= button.bit
    }

    public func contains(_ button: CButton) -> Bool {
        rawValue & button.bit != 0
    }

    public var isEmpty: Bool {
        rawValue == 0
    }
}

/// What a button element of a pad's physical input profile becomes.
public enum ProfileButtonRole: Equatable, Sendable {
    /// A bit in the XUSB word.
    case button(WireButton)
    /// An analog trigger, its value on 0...1.
    case trigger(PadSide)
    /// A digital trigger: held is fully pulled (the N64's Z and ZR).
    case fullTrigger(PadSide)
    /// A C button, which rails the right stick.
    case cButton(CButton)
}

public extension ProfileButtonRole {
    /// The side an analog trigger pulls; nil for a role read as held or not.
    var analogSide: PadSide? {
        switch self {
        case let .trigger(side): side
        case .button, .fullTrigger, .cButton: nil
        }
    }
}

/// What a two-axis element of a pad's physical input profile becomes.
public enum ProfileDirectionRole: Equatable, Sendable {
    /// Four XUSB d-pad bits.
    case dpad
    /// A stick, up-positive like the wire.
    case stick(PadSide)
}

public extension ProfileDirectionRole {
    /// The side a stick steers; nil for the d-pad.
    var stickSide: PadSide? {
        switch self {
        case .dpad: nil
        case let .stick(side): side
        }
    }
}

/// One input of a layout: the element names the framework may give it, the
/// first one the pad carries winning, and what it becomes on the wire.
public struct ProfileRow<Role: Equatable & Sendable>: Equatable, Sendable {
    public let names: [String]
    public let role: Role

    public init(_ names: [String], _ role: Role) {
        self.names = names
        self.role = role
    }
}

public enum ProfileLayoutKind: Equatable, Sendable {
    /// Apple's `GCInput…` names, read as the extended profile reads them.
    case generic
    /// The Nintendo Switch Online N64 controller under Android's policy.
    case n64
}

/// The table a pad without an extended profile is read through: element
/// name to wire role. GameController's names are plain strings (`GCInputButtonA`
/// is "Button A"); the engine's tests pin these literals against Apple's
/// constants.
public struct ProfileLayout: Equatable, Sendable {
    public let kind: ProfileLayoutKind
    public let buttons: [ProfileRow<ProfileButtonRole>]
    public let directions: [ProfileRow<ProfileDirectionRole>]

    public static func of(_ kind: ProfileLayoutKind) -> ProfileLayout {
        switch kind {
        case .generic: genericProfileLayout
        case .n64: n64ProfileLayout
        }
    }
}

/// Every name Apple documents for a gamepad, mapped as the extended path
/// maps the same inputs.
let genericProfileLayout = ProfileLayout(
    kind: .generic,
    buttons: [
        ProfileRow(["Button A"], .button(.faceA)),
        ProfileRow(["Button B"], .button(.faceB)),
        ProfileRow(["Button X"], .button(.faceX)),
        ProfileRow(["Button Y"], .button(.faceY)),
        ProfileRow(["Left Shoulder"], .button(.leftShoulder)),
        ProfileRow(["Right Shoulder"], .button(.rightShoulder)),
        ProfileRow(["Left Trigger"], .trigger(.left)),
        ProfileRow(["Right Trigger"], .trigger(.right)),
        ProfileRow(["Button Menu"], .button(.start)),
        ProfileRow(["Button Options"], .button(.back)),
        ProfileRow(["Button Home"], .button(.guide)),
        ProfileRow(["Left Thumbstick Button"], .button(.leftThumb)),
        ProfileRow(["Right Thumbstick Button"], .button(.rightThumb))
    ],
    directions: [
        ProfileRow(["Direction Pad"], .dpad),
        ProfileRow(["Left Thumbstick", "Thumbstick"], .stick(.left)),
        ProfileRow(["Right Thumbstick"], .stick(.right))
    ]
)

/// Android's N64 policy (dish-android `applyN64Key`): Z and ZR pull the
/// triggers fully, Home is Guide, Capture is Back, the C buttons rail the
/// right stick. Apple documents no names for the N64's C buttons, Z, ZR or
/// Capture, so each row lists the plausible ones; whatever the pad carries
/// that no row claims is logged at attach (`DEVCAPS PROFILE`).
let n64ProfileLayout = ProfileLayout(
    kind: .n64,
    buttons: [
        ProfileRow(["Button A"], .button(.faceA)),
        ProfileRow(["Button B"], .button(.faceB)),
        ProfileRow(["Left Shoulder", "Button L"], .button(.leftShoulder)),
        ProfileRow(["Right Shoulder", "Button R"], .button(.rightShoulder)),
        ProfileRow(["Left Trigger", "Button Z", "Z Button"], .fullTrigger(.left)),
        ProfileRow(["Right Trigger", "Button ZR", "ZR Button"], .fullTrigger(.right)),
        ProfileRow(["Button Menu", "Button Start"], .button(.start)),
        ProfileRow(["Button Home"], .button(.guide)),
        ProfileRow(["Button Share", "Button Capture"], .button(.back)),
        ProfileRow(["Button C Up", "C Up", "Right Thumbstick Up"], .cButton(.up)),
        ProfileRow(["Button C Down", "C Down", "Right Thumbstick Down"], .cButton(.down)),
        ProfileRow(["Button C Left", "C Left", "Right Thumbstick Left"], .cButton(.left)),
        ProfileRow(["Button C Right", "C Right", "Right Thumbstick Right"], .cButton(.right))
    ],
    directions: [
        ProfileRow(["Direction Pad"], .dpad),
        ProfileRow(["Left Thumbstick", "Thumbstick"], .stick(.left))
    ]
)

// MARK: - Choosing a layout

/// What made a pad an N64 pad, for the log.
public enum ProfileLayoutEvidence: String, Equatable, Sendable {
    case productCategory
    case vendorName
    case elementName
    case none
}

public struct ProfileLayoutChoice: Equatable, Sendable {
    public let kind: ProfileLayoutKind
    public let evidence: ProfileLayoutEvidence
}

private let n64Marker = "n64"
private let cButtonMarkers = ["button c ", "c up", "c down", "c left", "c right"]

/// The N64 layout when the framework's words name the pad (macOS calls it
/// "N64 Controller" over Bluetooth) or an element is a C button; Apple's
/// generic names otherwise.
public func chooseProfileLayout(productCategory: String, vendorName: String?, elementNames: [String]) -> ProfileLayoutChoice {
    let categoryNamesN64 = productCategory.lowercased().contains(n64Marker)
    let vendorNamesN64 = vendorName?.lowercased().contains(n64Marker) == true
    let carriesACButton = elementNames.contains { name in cButtonMarkers.contains { name.lowercased().hasPrefix($0) } }
    if categoryNamesN64 { return ProfileLayoutChoice(kind: .n64, evidence: .productCategory) }
    if vendorNamesN64 { return ProfileLayoutChoice(kind: .n64, evidence: .vendorName) }
    if carriesACButton { return ProfileLayoutChoice(kind: .n64, evidence: .elementName) }
    return ProfileLayoutChoice(kind: .generic, evidence: .none)
}

// MARK: - Resolving a layout against a pad

/// A row the pad carries: the name it carries it under.
public struct ProfileBinding<Role: Equatable & Sendable>: Equatable, Sendable {
    public let name: String
    public let role: Role
}

/// A layout read against one pad's elements: what binds, which rows the
/// pad lacks, and which of its elements no row claims.
public struct ResolvedProfile: Equatable, Sendable {
    public let buttons: [ProfileBinding<ProfileButtonRole>]
    public let directions: [ProfileBinding<ProfileDirectionRole>]
    /// Each missing row by its first candidate name.
    public let missing: [String]
    /// Each unclaimed element by its aliases, sorted and joined with "/".
    public let unclaimed: [String]

    /// A pad worth adopting steers with something and presses something.
    public var isAdoptable: Bool {
        let steers = !directions.isEmpty
        let presses = !buttons.isEmpty
        return steers && presses
    }
}

/// The parts the framework derives from a direction element: its four
/// buttons and two axes.
private let directionPartSuffixes = [" Up", " Down", " Left", " Right", " X Axis", " Y Axis"]

/// `elements` is one entry per element, holding every alias the framework
/// gives it. An element is claimed when a row binds one of its names or it
/// is a part of a bound direction element.
public func resolveProfile(_ layout: ProfileLayout, elements: [[String]]) -> ResolvedProfile {
    let present = Set(elements.flatMap(\.self))
    let buttons = layout.buttons.compactMap { row in bind(row, present: present) }
    let directions = layout.directions.compactMap { row in bind(row, present: present) }
    let missingButtons = layout.buttons.filter { bind($0, present: present) == nil }.compactMap(\.names.first)
    let missingDirections = layout.directions.filter { bind($0, present: present) == nil }.compactMap(\.names.first)
    let bound = Set(buttons.map(\.name) + directions.map(\.name))
    let parts = Set(directions.flatMap { binding in directionPartSuffixes.map { binding.name + $0 } })
    let claimed = bound.union(parts)
    let unclaimed = elements.filter { $0.allSatisfy { !claimed.contains($0) } }.map { $0.sorted().joined(separator: "/") }
    return ResolvedProfile(
        buttons: buttons,
        directions: directions,
        missing: missingButtons + missingDirections,
        unclaimed: unclaimed.sorted()
    )
}

private func bind<Role>(_ row: ProfileRow<Role>, present: Set<String>) -> ProfileBinding<Role>? {
    row.names.first(where: present.contains).map { ProfileBinding(name: $0, role: row.role) }
}

// MARK: - Sampling

/// A pad read through its profile: the pad sample plus the C buttons held,
/// which decide the right stick at conversion.
public struct ProfileSample: Equatable, Sendable {
    public var pad: PadSample
    public var cButtons: CButtonWord

    public init(pad: PadSample = PadSample(), cButtons: CButtonWord = CButtonWord()) {
        self.pad = pad
        self.cButtons = cButtons
    }

    /// A trigger two inputs pull reads the further pull.
    public mutating func pull(_ side: PadSide, _ value: Float) {
        switch side {
        case .left: pad.leftTrigger = max(pad.leftTrigger, value)
        case .right: pad.rightTrigger = max(pad.rightTrigger, value)
        }
    }

    public mutating func steer(_ side: PadSide, x: Float, y: Float) {
        switch side {
        case .left:
            pad.leftX = x
            pad.leftY = y
        case .right:
            pad.rightX = x
            pad.rightY = y
        }
    }

    public mutating func press(_ role: ProfileButtonRole) {
        switch role {
        case let .button(button): pad.pressed.insert(button)
        case let .trigger(side), let .fullTrigger(side): pull(side, 1)
        case let .cButton(button): cButtons.insert(button)
        }
    }
}

/// Full deflection one way, the other, or centred when both or neither are held.
func stickRail(positive: Bool, negative: Bool) -> Float {
    if positive == negative { return 0 }
    return positive ? 1 : -1
}

/// Any C button held takes the right stick: up and right positive, both of
/// a pair cancelling, as Android's `applyCButtonStick` has it.
public func padSample(from profile: ProfileSample) -> PadSample {
    guard !profile.cButtons.isEmpty else { return profile.pad }
    var sample = profile.pad
    sample.rightX = stickRail(positive: profile.cButtons.contains(.right), negative: profile.cButtons.contains(.left))
    sample.rightY = stickRail(positive: profile.cButtons.contains(.up), negative: profile.cButtons.contains(.down))
    return sample
}

/// The XUSB report a profile sample becomes.
public func wireReport(from profile: ProfileSample) -> GamepadReport {
    wireReport(padSample(from: profile))
}
