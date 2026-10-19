// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The manager's seams, scripted: a gateway that answers by path and records
// every call (and can hold one open until the test answers), session edges
// whose RTSP steps and control link answer as told, an RSA identity minted
// in memory, and the host half of the five pairing phases.

import Foundation
import Security
@testable import DishCore
@testable import DishEngine

final class ScriptedMoonlightGateway: MoonlightHostGateway, @unchecked Sendable {
    enum Kind: Equatable {
        case plain
        case secure
        case trusting
        case pinProven
        case forgetPin
    }

    struct Call: Equatable {
        var kind: Kind
        var path: String
        var query: String
        var timeout: TimeInterval
    }

    /// A request the host is slow to answer: the caller waits on it until the test answers.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MoonlightHttpReply, Never>?
        private var pending: MoonlightHttpReply?
        private(set) var asked = false

        func wait() async -> MoonlightHttpReply {
            await withCheckedContinuation { (continuation: CheckedContinuation<MoonlightHttpReply, Never>) in
                lock.lock()
                asked = true
                if let pending {
                    lock.unlock()
                    continuation.resume(returning: pending)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        func answer(_ reply: MoonlightHttpReply) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            if waiting == nil { pending = reply }
            lock.unlock()
            waiting?.resume(returning: reply)
        }
    }

    private let lock = NSLock()
    private var plainAnswers: [String: MoonlightHttpReply] = [:]
    private var secureAnswers: [String: MoonlightHttpReply] = [:]
    private var trustingAnswer = MoonlightHttpReply.unreachable
    private var holds: [String: Hold] = [:]
    private(set) var calls: [Call] = []
    private(set) var provenPins: [String: Data] = [:]
    /// Computed plain answers, for the pairing phases; nil falls through to the scripted ones.
    var onPlain: ((MoonlightHttpRequest) -> MoonlightHttpReply?)?

    static func reply(_ body: String, status: Int = 200) -> MoonlightHttpReply {
        MoonlightHttpReply(status: status, body: body)
    }

    func answerPlain(_ path: String, _ reply: MoonlightHttpReply) {
        lock.lock()
        plainAnswers[path] = reply
        lock.unlock()
    }

    func answerSecure(_ path: String, _ reply: MoonlightHttpReply) {
        lock.lock()
        secureAnswers[path] = reply
        lock.unlock()
    }

    func answerTrusting(_ reply: MoonlightHttpReply) {
        lock.lock()
        trustingAnswer = reply
        lock.unlock()
    }

    /// Hold every secure call to `path` until the test answers it.
    func holdSecure(_ path: String) -> Hold {
        let hold = Hold()
        lock.lock()
        holds[path] = hold
        lock.unlock()
        return hold
    }

    func holdPlain(_ path: String) -> Hold {
        let hold = Hold()
        lock.lock()
        holds["plain:" + path] = hold
        lock.unlock()
        return hold
    }

    func count(_ kind: Kind, _ path: String) -> Int {
        calls.filter { $0.kind == kind && $0.path == path }.count
    }

    func queries(_ path: String) -> [String] {
        calls.filter { $0.path == path }.map(\.query)
    }

    private func record(_ kind: Kind, _ request: MoonlightHttpRequest?, timeout: TimeInterval = 0) {
        let parts = request?.pathAndQuery.split(separator: "?", maxSplits: 1).map(String.init) ?? [""]
        lock.lock()
        calls.append(Call(kind: kind, path: parts.first ?? "", query: parts.count > 1 ? parts[1] : "", timeout: timeout))
        lock.unlock()
    }

    private func path(_ request: MoonlightHttpRequest) -> String {
        request.pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// The hold or the scripted answer for one call, read under the lock.
    private func scripted(_ kind: Kind, _ path: String) -> (hold: Hold?, reply: MoonlightHttpReply?) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .plain: return (holds["plain:" + path], plainAnswers[path])
        case .secure: return (holds[path], secureAnswers[path])
        case .trusting, .pinProven, .forgetPin: return (nil, trustingAnswer)
        }
    }

    func getPlain(_ request: MoonlightHttpRequest, timeout: TimeInterval) async -> MoonlightHttpReply {
        record(.plain, request, timeout: timeout)
        let found = scripted(.plain, path(request))
        if let hold = found.hold { return await hold.wait() }
        if let computed = onPlain?(request) { return computed }
        return found.reply ?? .unreachable
    }

    func getSecure(_ request: MoonlightHttpRequest, hostId _: String) async -> MoonlightHttpReply {
        record(.secure, request)
        let found = scripted(.secure, path(request))
        if let hold = found.hold { return await hold.wait() }
        return found.reply ?? .unreachable
    }

    func getSecureTrusting(_ request: MoonlightHttpRequest, certificateDER _: Data) async -> MoonlightHttpReply {
        record(.trusting, request)
        return scripted(.trusting, path(request)).reply ?? .unreachable
    }

    func pinProven(hostId: String, certificateDER: Data) {
        record(.pinProven, nil)
        lock.lock()
        provenPins[hostId] = certificateDER
        lock.unlock()
    }

    func forgetPin(hostId: String) {
        record(.forgetPin, nil)
        lock.lock()
        provenPins.removeValue(forKey: hostId)
        lock.unlock()
    }
}

/// RTSP steps that answer as told.
final class FakeMoonlightRtsp: MoonlightRtspStepping, @unchecked Sendable {
    let ok: Bool
    let ports: MoonlightStreamPorts
    private(set) var steps: [MoonlightRtspStep] = []

    init(ok: Bool, ports: MoonlightStreamPorts) {
        self.ok = ok
        self.ports = ports
    }

    func perform(_ step: MoonlightRtspStep, config _: MoonlightStreamConfig) async -> Bool {
        steps.append(step)
        return ok
    }

    var negotiated: MoonlightStreamPorts? {
        ok ? ports : nil
    }
}

/// Session edges with no sockets: the RTSP handshake and the control link
/// answer as told, and the live session records what the connection sends.
final class FakeMoonlightEdges: MoonlightSessionEdges, @unchecked Sendable {
    var rtspOk = true
    var controlConnects = true
    var ports = MoonlightStreamPorts(controlPort: 47999, videoPort: nil, audioPort: nil, connectData: 1, pingPayload: "")
    private(set) var rtspClients: [FakeMoonlightRtsp] = []
    private(set) var liveSessions: [RecordingLiveSession] = []
    /// The host's side of the last control link: what the connection hears, and the link's end.
    private(set) var onEvent: ((MoonlightEvent) -> Void)?
    private(set) var onClosed: (() -> Void)?

    func rtspClient(address _: String, port _: UInt16) -> MoonlightRtspStepping {
        let client = FakeMoonlightRtsp(ok: rtspOk, ports: ports)
        rtspClients.append(client)
        return client
    }

    func mediaPinger(address: String, ports _: MoonlightStreamPorts) -> MoonlightMediaPinger {
        MoonlightMediaPinger(address: address, videoPort: nil, audioPort: nil, payload: "")
    }

    func connectControl(
        address _: String,
        ports _: MoonlightStreamPorts,
        rikey _: Data,
        onEvent: @escaping (MoonlightEvent) -> Void,
        onClosed: @escaping () -> Void
    ) async -> MoonlightLiveSession? {
        guard controlConnects else { return nil }
        self.onEvent = onEvent
        self.onClosed = onClosed
        let session = RecordingLiveSession()
        liveSessions.append(session)
        return session
    }
}

/// An RSA-2048 identity minted in memory with a real self-signed certificate,
/// so it plays either end of the pairing and verifies with the key inside a PEM.
final class InMemoryMoonlightIdentity: MoonlightClientIdentity, MoonlightSignatureVerifier {
    let privateKey: SecKey
    let certificateDER: Data

    init?() {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let der = MoonlightCertificateMint.selfSigned(privateKey: key) else
        {
            return nil
        }
        privateKey = key
        certificateDER = der
    }

    var certificatePem: String {
        MoonlightCertificate.pem(fromDer: certificateDER)
    }

    var certificateSignature: Data {
        MoonlightCertificate.signatureBytes(der: certificateDER) ?? Data()
    }

    func sign(_ data: Data) -> Data? {
        SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil) as Data?
    }

    func verify(certificatePem: String, data: Data, signature: Data) -> Bool {
        guard let der = MoonlightCertificate.der(fromPem: certificatePem), let certificate = SecCertificateCreateWithData(
            nil,
            der as CFData
        ),
            let publicKey = SecCertificateCopyKey(certificate) else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }
}

/// The host half of the five phases, from the same primitives, answering the
/// manager's /pair requests by the phrase each identifies itself with. A
/// pairing that ends early still minted a PIN; the next attempt mints its own.
final class ReferenceMoonlightHost: @unchecked Sendable {
    private let identity: InMemoryMoonlightIdentity
    private let client: InMemoryMoonlightIdentity
    private let pin: () -> String
    private let lock = NSLock()
    private var aesKey = Data()
    private let serverSecret = Data((0 ..< 16).map { UInt8(0x10 + $0) })
    private let serverChallenge = Data((0 ..< 16).map { UInt8(0x20 + $0) })
    private var storedClientHash = Data()
    private var clientChallenge = Data()
    /// The phase refused with a bare `paired 0`, if any.
    var stopAt: Int?
    private(set) var paired = false

    init(identity: InMemoryMoonlightIdentity, client: InMemoryMoonlightIdentity, pin: @escaping () -> String) {
        self.identity = identity
        self.client = client
        self.pin = pin
    }

    var certificateDER: Data {
        identity.certificateDER
    }

    func answer(_ request: MoonlightHttpRequest) -> MoonlightHttpReply? {
        guard request.pathAndQuery.hasPrefix("/pair?") else { return nil }
        let params = Self.params(of: request.pathAndQuery)
        let refused = ScriptedMoonlightGateway.reply("<root status_code=\"200\"><paired>0</paired></root>")
        lock.lock()
        defer { lock.unlock() }
        if params["phrase"] == "getservercert", let salt = params["salt"] {
            aesKey = MoonlightPairingCrypto.pairingKey(salt: hexDecode(salt) ?? Data(), pin: pin())
            let certHex = hexEncodeLower(Data(identity.certificatePem.utf8))
            return stopAt == 1 ? refused : Self.paired("<plaincert>\(certHex)</plaincert>")
        }
        if let challenge = params["clientchallenge"] {
            guard stopAt != 2, let response = challengeResponse(challenge) else { return refused }
            return Self.paired("<challengeresponse>\(response)</challengeresponse>")
        }
        if let hash = params["serverchallengeresp"] {
            guard stopAt != 3, let secret = clientHashResponse(hash) else { return refused }
            return Self.paired("<pairingsecret>\(secret)</pairingsecret>")
        }
        if let secret = params["clientpairingsecret"] {
            paired = stopAt != 4 && verifyClient(secret)
            return ScriptedMoonlightGateway.reply("<root status_code=\"200\"><paired>\(paired ? 1 : 0)</paired></root>")
        }
        return ScriptedMoonlightGateway.reply("<root status_code=\"400\"/>", status: 400)
    }

    private static func paired(_ field: String) -> MoonlightHttpReply {
        ScriptedMoonlightGateway.reply("<root status_code=\"200\"><paired>1</paired>\(field)</root>")
    }

    private func challengeResponse(_ clientChallengeHex: String) -> String? {
        let encrypted = hexDecode(clientChallengeHex) ?? Data()
        guard let challenge = MoonlightPairingCrypto.aesEcbDecrypt(key: aesKey, data: encrypted) else { return nil }
        clientChallenge = challenge
        let hash = MoonlightPairingCrypto.sha256(clientChallenge, identity.certificateSignature, serverSecret)
        return MoonlightPairingCrypto.aesEcbEncrypt(key: aesKey, data: hash + serverChallenge).map(hexEncodeLower)
    }

    private func clientHashResponse(_ serverChallengeRespHex: String) -> String? {
        let encrypted = hexDecode(serverChallengeRespHex) ?? Data()
        guard let hash = MoonlightPairingCrypto.aesEcbDecrypt(key: aesKey, data: encrypted) else { return nil }
        storedClientHash = hash
        return identity.sign(serverSecret).map { hexEncodeLower(serverSecret + $0) }
    }

    private func verifyClient(_ clientPairingSecretHex: String) -> Bool {
        let secret = hexDecode(clientPairingSecretHex) ?? Data()
        let clientSecret = secret.prefix(16)
        let signature = secret.dropFirst(16)
        let expected = MoonlightPairingCrypto.sha256(serverChallenge, client.certificateSignature, clientSecret)
        guard MoonlightPairingCrypto.constantTimeEquals(expected, storedClientHash) else { return false }
        return client.verify(certificatePem: client.certificatePem, data: clientSecret, signature: signature)
    }

    static func params(of pathAndQuery: String) -> [String: String] {
        guard let query = pathAndQuery.split(separator: "?", maxSplits: 1).last else { return [:] }
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }
}
