// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A satellite session's own account of itself, as the Diagnostics window
// reads it: the heartbeat ack's epoch and controller bitmap against what this
// client last applied, whether the host reports a controller streaming, and
// which capabilities a descriptor advertised. Every answer the ack gives has
// an Unknown, because a session is live before its first enriched ack.

import Foundation

/// Whether the host agrees with this client about one thing: unknown until
/// the first enriched ack says.
public enum Agreement: Equatable, Sendable {
    case unknown
    case inStep
    case diverged
}

public enum SessionDiagnostics {
    public static let controllerBitmapWidth = 16
}

public func epochAgreement(hostEpoch: Int?, appliedEpoch: Int) -> Agreement {
    guard let hostEpoch else { return .unknown }
    return hostEpoch == appliedEpoch ? .inStep : .diverged
}

/// The controllers the host reports active against the ones it confirmed at
/// the last apply.
public func bitmapAgreement(hostBitmap: UInt16?, confirmedBitmap: UInt16) -> Agreement {
    guard let hostBitmap else { return .unknown }
    return hostBitmap == confirmedBitmap ? .inStep : .diverged
}

public func bitmapHasIndex(_ bitmap: UInt16, _ index: Int) -> Bool {
    guard index >= 0, index < SessionDiagnostics.controllerBitmapWidth else { return false }
    return bitmap & (UInt16(1) << UInt16(index)) != 0
}

/// The controller indices a bitmap names, lowest first.
public func bitmapIndices(_ bitmap: UInt16) -> [Int] {
    (0 ..< SessionDiagnostics.controllerBitmapWidth).filter { bitmapHasIndex(bitmap, $0) }
}

public enum Streaming: Equatable, Sendable {
    case unknown
    case yes
    case no
}

/// Whether the host reports this controller index active.
public func streamingOf(hostBitmap: UInt16?, controllerIndex: Int) -> Streaming {
    guard let hostBitmap else { return .unknown }
    return bitmapHasIndex(hostBitmap, controllerIndex) ? .yes : .no
}

/// The ack's backend byte: whether the host can create virtual controllers.
public enum HostBackend: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

public func hostBackendOf(_ backendAvailable: Bool?) -> HostBackend {
    guard let backendAvailable else { return .unknown }
    return backendAvailable ? .available : .unavailable
}

/// A capability a descriptor's caps word can advertise, in wire-bit order.
public enum WireCap: CaseIterable, Equatable, Sendable {
    case analogTriggers
    case rumble
    case motion
    case lightbar
    case triggerEffects
    case playerLeds
    case mic
    case speaker
    case hapticAudio
}

public func wireCapBit(_ cap: WireCap) -> UInt16 {
    switch cap {
    case .analogTriggers: ProtocolConstants.capAnalogTriggers
    case .rumble: ProtocolConstants.capRumble
    case .motion: ProtocolConstants.capMotion
    case .lightbar: ProtocolConstants.capLightbar
    case .triggerEffects: ProtocolConstants.capTriggerEffects
    case .playerLeds: ProtocolConstants.capPlayerLeds
    case .mic: ProtocolConstants.capMic
    case .speaker: ProtocolConstants.capSpeaker
    case .hapticAudio: ProtocolConstants.capHapticAudio
    }
}

public func advertisedCaps(_ caps: UInt16) -> [WireCap] {
    WireCap.allCases.filter { caps & wireCapBit($0) != 0 }
}
