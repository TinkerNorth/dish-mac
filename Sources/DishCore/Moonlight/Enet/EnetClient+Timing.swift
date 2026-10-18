// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The clock side: retransmit what the peer has not acknowledged, give up on
// a peer that has stopped acknowledging, and ping when the link is idle, by
// the fork's own rules (enet_protocol_check_timeouts, send_outgoing_commands).

import Foundation

extension EnetClient {
    /// Advance time: the retransmissions and the ping that are due.
    public func tick() -> [Data] {
        let time = now()
        var out: [Data] = []
        for index in sentReliable.indices {
            guard time - sentReliable[index].sentAtMs >= sentReliable[index].roundTripTimeout else { continue }
            if earliestTimeoutMs == 0 || sentReliable[index]
                .sentAtMs < earliestTimeoutMs { earliestTimeoutMs = sentReliable[index].sentAtMs }
            if hasTimedOut(sentReliable[index], at: time) {
                let command = sentReliable[index]
                let place = "channel \(command.channel) seq \(command.reliableSequence)"
                giveUp("peer stopped acknowledging: \(place) unacked \(time - earliestTimeoutMs) ms over \(command.sendAttempts) sends")
                return out
            }
            out.append(retransmit(at: index, time: time))
        }
        if pingIsDue(at: time) {
            out.append(buildPing(at: time))
        }
        return out
    }

    /// Give up after the maximum outright, or after the minimum once the
    /// command has been resent enough times that its doubling window has
    /// passed the limit.
    private func hasTimedOut(_ command: Outgoing, at time: Int64) -> Bool {
        let waited = time - earliestTimeoutMs
        if waited >= EnetProtocol.timeoutMaximumMs { return true }
        let attemptWindow = 1 << min(max(command.sendAttempts - 1, 0), 30)
        return attemptWindow >= EnetProtocol.timeoutLimit && waited >= EnetProtocol.timeoutMinimumMs
    }

    /// Re-wrapped rather than replayed: the header's sent time is what the
    /// peer echoes back to measure the round trip, so a stale one poisons
    /// its estimate. The timeout scales by the attempts before this resend,
    /// as the fork recomputes it before it requeues the command.
    private func retransmit(at index: Int, time: Int64) -> Data {
        let attempts = sentReliable[index].sendAttempts
        let scale = attempts < EnetProtocol.timeoutLimit ? max(1, attempts) : EnetProtocol.timeoutLimit
        sentReliable[index].roundTripTimeout = peerRoundTripTimeout() * Int64(scale)
        sentReliable[index].sendAttempts = attempts + 1
        sentReliable[index].sentAtMs = time
        stats.retransmits += 1
        return wrap(sentReliable[index].command, at: time)
    }

    /// Only while connected, with nothing reliable outstanding, once half a
    /// second has passed since the peer last acknowledged anything: a peer
    /// that is answering needs no keepalive, and one that owes an
    /// acknowledgement is already on the retransmit clock.
    private func pingIsDue(at time: Int64) -> Bool {
        state == .connected && sentReliable.isEmpty && time - lastReceiveMs >= EnetProtocol.pingIntervalMs
    }

    private func buildPing(at time: Int64) -> Data {
        systemReliableSequence &+= 1
        var writer = ByteWriter(capacity: EnetProtocol.pingLength)
        let ping = EnetProtocol.commandPing | EnetProtocol.flagAcknowledge
        EnetWire.commandHeader(&writer, command: ping, channel: EnetProtocol.systemChannel, reliableSequence: systemReliableSequence)
        return track(channel: EnetProtocol.systemChannel, sequence: systemReliableSequence, command: writer.data, at: time)
    }

    /// The peer's retransmission timeout: the estimate plus the lesser of
    /// itself and four times the variance, capped at a fifth of the maximum.
    func peerRoundTripTimeout() -> Int64 {
        let variance = 4 * max(1, roundTripTimeVariance)
        let timeout = roundTripTime + min(roundTripTime, variance)
        return min(max(timeout, 1), EnetProtocol.timeoutMaximumMs / 5)
    }
}
