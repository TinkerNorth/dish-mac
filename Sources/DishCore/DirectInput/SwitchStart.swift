// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A Switch-family pad on USB (the Pro, the N64, the SNES pad) streams its
// full 0x30 reports only after three commands: the USB handshake, the
// timeout disable that keeps it reporting, and subcommand 0x03 "full report
// mode". macOS's driver does not leave the N64 streaming, so Dish sends them
// itself to a pad it reads that stays quiet. The packets are dish-android's
// kSwitchInitPackets (usb_parsers.cpp), each one full USB packet long, as
// SDL writes them.

/// One packet of the start sequence, in the order the pad takes them.
public enum SwitchStartStep: CaseIterable, Equatable, Sendable {
    case handshake
    case disableTimeout
    case fullReportMode

    /// The packet after this one; nil once the report mode is set.
    public var next: SwitchStartStep? {
        switch self {
        case .handshake: .disableTimeout
        case .disableTimeout: .fullReportMode
        case .fullReportMode: nil
        }
    }
}

/// One USB packet: every start packet is padded to it.
public let switchStartPacketBytes = 64

private let handshakeBytes: [UInt8] = [0x80, 0x02]
private let disableTimeoutBytes: [UInt8] = [0x80, 0x04]
/// Report 0x01: the packet counter, the 8-byte neutral rumble pattern, then
/// subcommand 0x03 with argument 0x30.
private let fullReportModeBytes: [UInt8] = [0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30]

/// The step's packet, padded to one USB packet.
public func switchStartPacket(_ step: SwitchStartStep) -> [UInt8] {
    let bytes = switchStartBytes(step)
    let padding = [UInt8](repeating: 0, count: switchStartPacketBytes - bytes.count)
    return bytes + padding
}

/// The output report the packet is: its first byte.
public func switchStartReportId(_ step: SwitchStartStep) -> UInt8 {
    switchStartBytes(step)[0]
}

private func switchStartBytes(_ step: SwitchStartStep) -> [UInt8] {
    switch step {
    case .handshake: handshakeBytes
    case .disableTimeout: disableTimeoutBytes
    case .fullReportMode: fullReportModeBytes
    }
}

/// The watch's timing.
public enum SwitchStreamRule {
    /// After the opening, Apple's own handshake runs first: a pad that
    /// starts streaming in this time is never sent anything.
    public static let graceMs: Int64 = 1000
    /// Full reports this long overdue mean the stream stopped.
    public static let stallMs: Int64 = 2000
    /// Between sequences while the pad stays quiet.
    public static let retryMs: Int64 = 3000
    /// Between sequences once `quickStarts` of them brought no stream.
    public static let slowRetryMs: Int64 = 10000
    public static let quickStarts = 3
}

/// What the reader does for one pad at a tick.
public enum SwitchStreamAction: Equatable, Sendable {
    /// Full reports arrive: nothing to do.
    case streaming
    /// Too soon to send anything.
    case wait
    /// Send this packet now.
    case send(SwitchStartStep)
}

/// One pad's start sequence over time: never sent to a pad that streams, one
/// packet per tick, and less often while sequences bring nothing.
public struct SwitchStreamWatch: Equatable, Sendable {
    public let openedMs: Int64
    /// When the last sequence's handshake went out.
    public private(set) var lastStartMs: Int64?
    /// The packet the sequence in flight sends next.
    public private(set) var nextStep: SwitchStartStep?
    /// Sequences sent since the pad last streamed.
    public private(set) var startsWithoutStream = 0

    public init(openedMs: Int64) {
        self.openedMs = openedMs
    }

    public func due(lastFullReportMs: Int64?, nowMs: Int64) -> SwitchStreamAction {
        if isStreaming(lastFullReportMs, nowMs) { return .streaming }
        if let step = nextStep { return .send(step) }
        return mayStart(lastFullReportMs, nowMs) ? .send(.handshake) : .wait
    }

    public mutating func noteSent(_ step: SwitchStartStep, nowMs: Int64) {
        if step == .handshake {
            lastStartMs = nowMs
            startsWithoutStream += 1
        }
        nextStep = step.next
    }

    /// The pad streams: a sequence in flight is dropped, and a later stall
    /// starts again at once, with the quick retries.
    public mutating func noteStreaming() {
        nextStep = nil
        lastStartMs = nil
        startsWithoutStream = 0
    }

    private func isStreaming(_ lastFullReportMs: Int64?, _ nowMs: Int64) -> Bool {
        guard let lastFullReportMs else { return false }
        return nowMs - lastFullReportMs < SwitchStreamRule.stallMs
    }

    /// A pad that never streamed waits out the grace; after a sequence, the
    /// retry interval, slower once the quick starts are spent.
    private func mayStart(_ lastFullReportMs: Int64?, _ nowMs: Int64) -> Bool {
        let neverStreamed = lastFullReportMs == nil
        let inGrace = neverStreamed && nowMs - openedMs < SwitchStreamRule.graceMs
        guard !inGrace else { return false }
        guard let lastStartMs else { return true }
        let quick = startsWithoutStream < SwitchStreamRule.quickStarts
        let interval = quick ? SwitchStreamRule.retryMs : SwitchStreamRule.slowRetryMs
        return nowMs - lastStartMs >= interval
    }
}
