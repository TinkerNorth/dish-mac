// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What Dish writes to a Steam Controller as it reads it: the 2015 pad is
// quieted when Dish starts and restored on every release (its settings
// persist until it reboots, so a release that skipped the restore would
// strand a mute pad); the 2026 pad gets lizard mode off and its IMU on,
// lizard mode again every few seconds, and only a motor stop on release,
// since its firmware's watchdog turns lizard mode back on by itself. A
// receiver's slot is configured when its controller arrives: the 2015
// receiver is asked what a slot holds, the 2026 one waits for a report.

import Foundation

public enum SteamGeneration: Equatable, Sendable {
    /// The 2015 pad: vendor packets on report id 0.
    case original
    /// The 2015 pad over Bluetooth LE: its packets in segments of report 3.
    case originalOverBluetooth
    /// The 2026 pad: numbered reports, its settings on feature report 1, on
    /// either link.
    case triton
}

/// One report Dish writes to the pad.
public struct SteamWrite: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case feature
        case output
    }

    public let kind: Kind
    public let reportId: UInt8
    /// The report as IOKit takes it: report id 0 carries no id byte; a
    /// numbered report starts with its id.
    public let bytes: [UInt8]

    public init(kind: Kind, reportId: UInt8, bytes: [UInt8]) {
        self.kind = kind
        self.reportId = reportId
        self.bytes = bytes
    }
}

public struct SteamPlan: Equatable, Sendable {
    public let generation: SteamGeneration
    /// A receiver's slot holds a controller only while one is connected to it.
    public let receiver: Bool

    public init(generation: SteamGeneration, receiver: Bool) {
        self.generation = generation
        self.receiver = receiver
    }

    /// Dish starts reading: a wired pad is configured at once.
    public var onClaim: [SteamWrite] {
        guard receiver else { return configure }
        return askSlot
    }

    /// A controller arrived on the interface, fresh from a boot.
    public var onConnect: [SteamWrite] {
        configure
    }

    /// Dish stops reading: the pad is given back as it came.
    public var onRelease: [SteamWrite] {
        switch generation {
        case .original: features(steamConfigReports(.restore))
        case .originalOverBluetooth: features(steamBleConfigReports(.restore))
        case .triton: [SteamWrite(kind: .output, reportId: TritonReportId.hapticRumble, bytes: tritonRumbleReport(left: 0, right: 0))]
        }
    }

    /// Sent every `TritonRumbleRule.lizardRefreshMs` while a controller is read.
    public var refresh: [SteamWrite] {
        switch generation {
        case .original, .originalOverBluetooth: []
        case .triton: features([tritonLizardOffReport()])
        }
    }

    public var refreshesLizardMode: Bool {
        generation == .triton
    }

    /// The 2026 pad has rumble motors; the 2015 pad has none.
    public var rumbles: Bool {
        generation == .triton
    }

    private var configure: [SteamWrite] {
        switch generation {
        case .original: features(steamConfigReports(.quiet))
        case .originalOverBluetooth: features(steamBleConfigReports(.quiet))
        case .triton: features([tritonLizardOffReport(), tritonSensorsOnReport()])
        }
    }

    /// The 2015 receiver answers with a connect or disconnect event.
    private var askSlot: [SteamWrite] {
        switch generation {
        case .original: features([steamReceiverStateRequest()])
        case .originalOverBluetooth, .triton: []
        }
    }

    private func features(_ reports: [[UInt8]]) -> [SteamWrite] {
        reports.map { SteamWrite(kind: .feature, reportId: featureReportId, bytes: $0) }
    }

    private var featureReportId: UInt8 {
        switch generation {
        case .original: 0
        case .originalOverBluetooth: SteamBleLayout.reportId
        case .triton: TritonReportId.controllerFeature
        }
    }
}

/// The plan for a Valve model; nil for any other pad.
public func steamPlan(_ model: DirectModel) -> SteamPlan? {
    switch model.decoder {
    case .steamController: SteamPlan(generation: .original, receiver: model.receiver)
    case .steamControllerBle: SteamPlan(generation: .originalOverBluetooth, receiver: model.receiver)
    case .steamTriton: SteamPlan(generation: .triton, receiver: model.receiver)
    case .switchReport, .hidGamepad, .xusb: nil
    }
}
