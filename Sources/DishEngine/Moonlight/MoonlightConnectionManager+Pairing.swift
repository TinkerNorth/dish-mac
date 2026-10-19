// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The PIN pairing as the manager drives it. The host is first asked whether
/// it already trusts this device: it authorises by client certificate, so a
/// device that forgot a host the host still trusts is answered without a
/// PIN, and that answer is recorded like a pairing. Else the five phases,
/// phase 1 waiting on the human. Nothing is written on this side, the pin
/// included, until phase 5 has confirmed it, so a cancel or a forget that
/// lands meanwhile leaves this side as it was.
extension MoonlightConnectionManager {
    static let pinRange = 10000

    func pairHost(_ host: MoonlightHost) async -> Bool {
        pairingInFlight.insert(host.id)
        defer { pairingInFlight.remove(host.id) }
        let epoch = epochOf(host.id)
        let generation = pairingGenerations[host.id, default: 0]
        let answering = await answeringNow(host)
        let trusted = await isPaired(answering)
        guard stillPairing(host.id, epoch: epoch, generation: generation) else { return false }
        if trusted {
            markVerified(host.id)
            rememberPaired(answering, paired: true, answeredUniqueId: answering.uniqueId)
            events.send(.paired(answering))
            return true
        }
        return await pair(answering, epoch: epoch, generation: generation)
    }

    /// Ends a pairing in flight for the user: whatever the host answers
    /// afterwards, nothing is written or announced.
    func cancelPairing(hostId: String) {
        pairingGenerations[hostId, default: 0] += 1
    }

    private func stillPairing(_ hostId: String, epoch: Int, generation: Int) -> Bool {
        !forgottenSince(hostId, epoch) && pairingGenerations[hostId, default: 0] == generation
    }

    /// The host with the uniqueid it answers with now, the machine a pairing
    /// proves; with the one remembered when it does not answer.
    private func answeringNow(_ host: MoonlightHost) async -> MoonlightHost {
        let answered = await plainServerInfo(host.endpoint)?.uniqueId ?? ""
        var answering = host
        answering.uniqueId = answered.isEmpty ? (store.host(id: host.id)?.uniqueId ?? "") : answered
        return answering
    }

    private func pair(_ host: MoonlightHost, epoch: Int, generation: Int) async -> Bool {
        guard let identity else {
            events.send(.pairingFailed(
                host: host,
                reason: MoonlightPairingFailure(phase: 1, kind: .noIdentity, httpStatus: 0, hostSaid: "")
            ))
            return false
        }
        let pin = randomPin()
        events.send(.pairingPinReady(host: host, pin: pin))
        var pairing = MoonlightPairing(identity: identity, pin: pin, random: random)
        let outcome = await runPhases(host.endpoint, pairing: &pairing, identity: identity)
        guard stillPairing(host.id, epoch: epoch, generation: generation) else { return false }
        switch outcome {
        case let .proven(der):
            gateway.pinProven(hostId: host.id, certificateDER: der)
            markVerified(host.id)
            rememberPaired(host, paired: true, answeredUniqueId: host.uniqueId)
            events.send(.paired(host))
            return true
        case let .refused(failure):
            events.send(.pairingFailed(host: host, reason: failure))
            return false
        }
    }

    enum PhaseOutcome: Equatable {
        /// The host's certificate, proved by the five phases.
        case proven(Data)
        case refused(MoonlightPairingFailure)
    }

    private struct PhaseAnswer {
        let reply: MoonlightHttpReply
        let parsed: MoonlightPairReply?
    }

    private func ask(
        _ endpoint: MoonlightEndpoint,
        _ params: [(String, String)],
        timeout: TimeInterval = MoonlightHttpTransport.plainTimeout
    ) async -> PhaseAnswer {
        let reply = await gateway.getPlain(MoonlightUrls.pair(endpoint, tls: false, params: params, nonce: nonce()), timeout: timeout)
        return PhaseAnswer(reply: reply, parsed: MoonlightXml.pairReply(reply.body))
    }

    private func refusal(_ phase: Int, _ kind: MoonlightPairingFailure.Kind, _ reply: MoonlightHttpReply) -> MoonlightPairingFailure {
        MoonlightPairingFailure(
            phase: phase,
            kind: kind,
            httpStatus: reply.status,
            hostSaid: MoonlightXml.status(reply.body)?.message ?? ""
        )
    }

    /// Phases 1 to 4 on plain HTTP, then phase 5 over mutual TLS trusting the
    /// certificate they proved, whatever is pinned.
    private func runPhases(
        _ endpoint: MoonlightEndpoint,
        pairing: inout MoonlightPairing,
        identity: MoonlightPairingIdentity
    ) async -> PhaseOutcome {
        let der: Data
        switch await phaseOne(endpoint, pairing: &pairing) {
        case let .refused(failure): return .refused(failure)
        case let .proven(proved): der = proved
        }
        if let failure = await phaseTwo(endpoint, pairing: &pairing) { return .refused(failure) }
        if let failure = await phaseThree(endpoint, pairing: &pairing, identity: identity) { return .refused(failure) }
        if let failure = await phaseFour(endpoint, pairing: &pairing) { return .refused(failure) }
        return await phaseFive(endpoint, certificateDER: der)
    }

    /// Phase 1 waits on a human, not on the network: the host answers once
    /// the PIN is typed into its own page.
    private func phaseOne(_ endpoint: MoonlightEndpoint, pairing: inout MoonlightPairing) async -> PhaseOutcome {
        let answer = await ask(endpoint, pairing.phase1Params(uniqueId: uniqueId), timeout: MoonlightHttpTransport.pinTimeout)
        guard let pem = answer.parsed?.plainCert.flatMap(Self.asciiFromHex), pairing.onPhase1(serverCertificatePem: pem),
              let der = MoonlightCertificate.der(fromPem: pem) else { return .refused(refusal(1, .noCertificate, answer.reply)) }
        return .proven(der)
    }

    private func phaseTwo(_ endpoint: MoonlightEndpoint, pairing: inout MoonlightPairing) async -> MoonlightPairingFailure? {
        guard let params = pairing.phase2Params(uniqueId: uniqueId) else { return refusal(2, .noChallengeResponse, .unreachable) }
        let answer = await ask(endpoint, params)
        guard let challenge = answer.parsed?.challengeResponse, pairing.onPhase2(challengeResponseHex: challenge) else {
            return refusal(2, .noChallengeResponse, answer.reply)
        }
        return nil
    }

    /// The host is authentic when its phase-2 hash matches the secret it now
    /// reveals and the secret carries its certificate's signature; a wrong
    /// PIN fails here, on this side, before anything of ours is signed.
    private func phaseThree(
        _ endpoint: MoonlightEndpoint,
        pairing: inout MoonlightPairing,
        identity: MoonlightPairingIdentity
    ) async -> MoonlightPairingFailure? {
        guard let params = pairing.phase3Params(uniqueId: uniqueId) else { return refusal(3, .noPairingSecret, .unreachable) }
        let answer = await ask(endpoint, params)
        guard let secret = answer.parsed?.pairingSecret else { return refusal(3, .noPairingSecret, answer.reply) }
        guard pairing.onPhase3(pairingSecretHex: secret, verifier: identity) else { return refusal(3, .hostNotAuthentic, answer.reply) }
        return nil
    }

    private func phaseFour(_ endpoint: MoonlightEndpoint, pairing: inout MoonlightPairing) async -> MoonlightPairingFailure? {
        guard let params = pairing.phase4Params(uniqueId: uniqueId) else { return refusal(4, .notConfirmed, .unreachable) }
        let answer = await ask(endpoint, params)
        guard answer.parsed?.paired == true else { return refusal(4, .notConfirmed, answer.reply) }
        return nil
    }

    private func phaseFive(_ endpoint: MoonlightEndpoint, certificateDER der: Data) async -> PhaseOutcome {
        let request = MoonlightUrls.pair(endpoint, tls: true, params: MoonlightPairing.phase5Params(uniqueId: uniqueId), nonce: nonce())
        let reply = await gateway.getSecureTrusting(request, certificateDER: der)
        guard MoonlightXml.pairReply(reply.body)?.paired == true else { return .refused(refusal(5, .notConfirmed, reply)) }
        return .proven(der)
    }

    /// Four digits from the injected randomness.
    private func randomPin() -> String {
        let bytes = [UInt8](random(2))
        let value = Int(bytes.first ?? 0) << 8 | Int(bytes.dropFirst().first ?? 0)
        return String(format: "%04d", value % Self.pinRange)
    }

    /// The PEM text a host sends as hex; nil for anything that is not hex.
    static func asciiFromHex(_ hex: String) -> String? {
        var bytes = Data(capacity: hex.utf8.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), let byte = UInt8(hex[index ..< next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .ascii)
    }
}
