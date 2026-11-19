// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One controller as the fleet's controller database describes it, schema 1
// (dish-website `docs/controller-db.md`, section 4): the identity it shows,
// the family that parses it, the Direct rule with the Mac's override
// applied, what it can do, what its hardware should look like at attach,
// and its support standing. A record names things the binary already
// knows; it carries no prose and no bytes to send.

import Foundation

/// The parser families the Direct paths compile, by the ids the database
/// fixes; `requires.families` uses the same ids.
public enum ControllerFamily: String, CaseIterable, Equatable, Sendable {
    case xinput360
    case xinput360Wireless
    case xboxOneGip
    case dualshock4
    case dualsense
    case switchProUsb
    case switchN64Usb
    case stadia
    case hid
    case steamController
    case steamTriton
    case steamControllerBle
}

/// The four button orders a `hid` record may name.
public enum ControllerMapping: String, CaseIterable, Equatable, Sendable {
    case western
    case nintendoSwitch = "switch"
    case eightBitDo = "eightbitdo"
    case playStationClassic = "playstationClassic"
}

/// `input.direct.rule`, as the data words it.
public enum ControllerDirectRule: String, CaseIterable, Equatable, Sendable {
    case auto
    case optIn
    case whenOsCannot
}

public enum ControllerVerification: String, CaseIterable, Equatable, Sendable {
    case verified
    case imported
    case crowd
    case guessed
    case flagged
}

public enum ControllerTransport: String, CaseIterable, Equatable, Sendable {
    case usb
    case bluetooth
}

/// How an output report leaves the host.
public enum ControllerOutputRoute: String, CaseIterable, Equatable, Sendable {
    case interruptOut
    case setReport
}

/// One known problem, worded only in the strings under `issue.<id>`.
public struct ControllerIssue: Equatable, Sendable {
    public let id: String
    /// The device the issue was seen on; nil when it is any.
    public let device: String?
    /// Platform name to major version; empty when it is any.
    public let os: [String: Int]
    /// Nil when the issue is on every transport.
    public let transport: ControllerTransport?
    public let lane: String?
    public let status: String?

    public init(
        id: String,
        device: String? = nil,
        os: [String: Int] = [:],
        transport: ControllerTransport? = nil,
        lane: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.device = device
        self.os = os
        self.transport = transport
        self.lane = lane
        self.status = status
    }
}

/// What the hardware should look like at attach; nil is "unknown".
public struct ControllerExpect: Equatable, Sendable {
    public let endpointIn: Bool?
    public let endpointOut: Bool?

    public init(endpointIn: Bool? = nil, endpointOut: Bool? = nil) {
        self.endpointIn = endpointIn
        self.endpointOut = endpointOut
    }
}

public struct ControllerInputCapabilities: Equatable, Sendable {
    public let motion: Bool
    public let touchpad: Bool
    public let trackpads: Int
    public let battery: Bool
    public let extendedButtons: Bool

    public init(motion: Bool = false, touchpad: Bool = false, trackpads: Int = 0, battery: Bool = false, extendedButtons: Bool = false) {
        self.motion = motion
        self.touchpad = touchpad
        self.trackpads = trackpads
        self.battery = battery
        self.extendedButtons = extendedButtons
    }
}

public struct ControllerOutputCapabilities: Equatable, Sendable {
    public let rumble: Bool
    public let triggerRumble: Bool
    public let lightbar: Bool
    public let playerLeds: Bool
    public let micLed: Bool
    public let triggerEffects: Bool

    public init(
        rumble: Bool = false,
        triggerRumble: Bool = false,
        lightbar: Bool = false,
        playerLeds: Bool = false,
        micLed: Bool = false,
        triggerEffects: Bool = false
    ) {
        self.rumble = rumble
        self.triggerRumble = triggerRumble
        self.lightbar = lightbar
        self.playerLeds = playerLeds
        self.micLed = micLed
        self.triggerEffects = triggerEffects
    }
}

public struct ControllerRecord: Equatable, Sendable {
    public let id: String
    public let requiredFamilies: [String]
    public let requiredOps: [String]
    /// Lowercase `vid:pid`, as the pad shows itself over USB and over Bluetooth.
    public let usb: [String]
    public let bluetooth: [String]
    /// `input.protocol.ref`, kept as written so a family this build does
    /// not know still reads.
    public let familyId: String
    public let mapping: ControllerMapping?
    /// `platforms.mac.direct.rule` when the record has one, else `input.direct.rule`.
    public let directRule: ControllerDirectRule
    public let inputCapabilities: ControllerInputCapabilities
    public let outputRoute: ControllerOutputRoute?
    public let initKind: String
    public let outputCapabilities: ControllerOutputCapabilities
    public let expect: ControllerExpect
    public let verification: ControllerVerification
    public let issues: [ControllerIssue]

    public init(
        id: String,
        requiredFamilies: [String] = [],
        requiredOps: [String] = [],
        usb: [String] = [],
        bluetooth: [String] = [],
        familyId: String,
        mapping: ControllerMapping? = nil,
        directRule: ControllerDirectRule = .auto,
        inputCapabilities: ControllerInputCapabilities = ControllerInputCapabilities(),
        outputRoute: ControllerOutputRoute? = nil,
        initKind: String = "none",
        outputCapabilities: ControllerOutputCapabilities = ControllerOutputCapabilities(),
        expect: ControllerExpect = ControllerExpect(),
        verification: ControllerVerification = .verified,
        issues: [ControllerIssue] = []
    ) {
        self.id = id
        self.requiredFamilies = requiredFamilies
        self.requiredOps = requiredOps
        self.usb = usb
        self.bluetooth = bluetooth
        self.familyId = familyId
        self.mapping = mapping
        self.directRule = directRule
        self.inputCapabilities = inputCapabilities
        self.outputRoute = outputRoute
        self.initKind = initKind
        self.outputCapabilities = outputCapabilities
        self.expect = expect
        self.verification = verification
        self.issues = issues
    }

    /// Nil for a family this build has no name for.
    public var family: ControllerFamily? {
        ControllerFamily(rawValue: familyId)
    }
}

/// `controllers.json`: one published version of every record.
public struct ControllerDatabase: Equatable, Sendable {
    public let dbVersion: Int
    public let records: [ControllerRecord]

    public init(dbVersion: Int, records: [ControllerRecord]) {
        self.dbVersion = dbVersion
        self.records = records
    }
}
