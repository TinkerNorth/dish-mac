// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A Moonlight host on loopback, as far as the manager and its sockets need
// one: plain HTTP for the probe and the five pairing phases (the reference host
// answers them), mutual TLS for everything a paired client asks and a 401 for
// anyone else, an RTSP host that hands out the media and control ports, two
// media ports that record their pings, and the control port that opens the
// sealed packets. Every port is ephemeral, so the host record carries the two
// HTTP ports and the launch reply names the RTSP one, as a real host's do.

import Foundation
import Security
@testable import DishCore
@testable import DishEngine

final class FakeMoonlightHost: @unchecked Sendable {
    static let uniqueId = "fake-moonlight-host"
    static let hostName = "Fake PC"
    static let appList = "<root status_code=\"200\"><App><AppTitle>Desktop</AppTitle><ID>1</ID></App></root>"
    static let connectData: UInt32 = 4_270_471_497
    static let pingPayload = "9A615601970AEC19"

    let pairing: ReferenceMoonlightHost
    let plain = MoonlightLoopbackServer()
    let secure = MoonlightLoopbackServer()
    let rtsp = MoonlightLoopbackRtspHost()
    let video = MoonlightLoopbackUdp()
    let audio = MoonlightLoopbackUdp()
    let control = FakeMoonlightControlHost()
    private let tlsIdentity: SecIdentity
    private let lock = NSLock()
    private var launchTargets: [String] = []
    private var cancels = 0
    private(set) var plainPort: UInt16 = 0
    private(set) var securePort: UInt16 = 0

    /// `identity` signs the pairing and `tlsIdentity` is the same key as the
    /// listener presents it; `client` is the dish the host will accept.
    init(identity: MoonlightClientIdentity, tlsIdentity: SecIdentity, client: MoonlightPairingIdentity, pin: @escaping () -> String) {
        pairing = ReferenceMoonlightHost(identity: identity, client: client, pin: pin)
        self.tlsIdentity = tlsIdentity
    }

    func start() throws {
        let controlPort = try control.start()
        let videoPort = try video.start()
        let audioPort = try audio.start()
        scriptRtsp(control: controlPort, video: videoPort, audio: audioPort)
        _ = try rtsp.start()
        plain.respond { [weak self] target in self?.answerPlain(target) }
        plainPort = try plain.start()
        secure.respond { [weak self] target in self?.answerSecure(target) }
        securePort = try secure.start(identity: tlsIdentity, requireClientCertificate: true)
    }

    func stop() {
        plain.stop()
        secure.stop()
        rtsp.stop()
        video.stop()
        audio.stop()
        control.stop()
    }

    /// The host as a record remembers it, before any pairing.
    var host: MoonlightHost {
        MoonlightHost(name: Self.hostName, address: "127.0.0.1", httpPort: plainPort, httpsPort: securePort, uniqueId: Self.uniqueId)
    }

    /// Every /launch and /resume target, query included.
    func launches() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return launchTargets
    }

    func cancelCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    // MARK: - The host's answers

    /// Sunshine's shapes, with this host's ports in the Transport lines.
    private func scriptRtsp(control: UInt16, video: UInt16, audio: UInt16) {
        let session = "Session: DEADBEEFCAFE;timeout = 90\r\n"
        rtsp.reply("OPTIONS", "RTSP/1.0 200 OK\r\nCSeq: 1\r\nPublic: DESCRIBE, SETUP, TEARDOWN, PLAY\r\n\r\n")
        rtsp.reply("DESCRIBE", "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\nv=0\r\na=fmtp:97 surround-params=21101\r\n")
        rtsp.reply(
            "SETUP streamid=audio",
            "RTSP/1.0 200 OK\r\nCSeq: 3\r\n" + session + "Transport: server_port=\(audio)\r\n"
                + "X-SS-Ping-Payload: \(Self.pingPayload)\r\n\r\n"
        )
        rtsp.reply("SETUP streamid=video", "RTSP/1.0 200 OK\r\nCSeq: 4\r\n" + session + "Transport: server_port=\(video)\r\n\r\n")
        rtsp.reply(
            "SETUP streamid=control",
            "RTSP/1.0 200 OK\r\nCSeq: 5\r\n" + session + "Transport: server_port=\(control)\r\n"
                + "X-SS-Connect-Data: \(Self.connectData)\r\n\r\n"
        )
        rtsp.reply("ANNOUNCE", "RTSP/1.0 200 OK\r\nCSeq: 6\r\n\r\n")
        rtsp.reply("PLAY", "RTSP/1.0 200 OK\r\nCSeq: 7\r\n\r\n")
    }

    /// Plain HTTP: /serverinfo for anyone (a PairStatus of 0, as Sunshine hands
    /// every plaintext caller) and the pairing phases.
    private func answerPlain(_ target: String) -> MoonlightLoopbackServer.Answer? {
        if target.hasPrefix("/serverinfo") { return Self.http(serverInfo(pairStatus: 0)) }
        guard target.hasPrefix("/pair") else { return nil }
        let request = MoonlightHttpRequest(host: "127.0.0.1", port: plainPort, tls: false, pathAndQuery: target)
        return pairing.answer(request).map(Self.http)
    }

    /// Mutual TLS: a client the host has not paired is refused as Wolf refuses
    /// it, under a 401; a paired one is answered.
    private func answerSecure(_ target: String) -> MoonlightLoopbackServer.Answer? {
        guard pairing.paired else {
            return Self.http(MoonlightHttpReply(status: 401, body: "<root status_code=\"401\" status_message=\"Unauthorized\"/>"))
        }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        switch path {
        case "/serverinfo": return Self.http(serverInfo(pairStatus: 1))
        case "/pair": return Self.http(MoonlightHttpReply(status: 200, body: "<root status_code=\"200\"><paired>1</paired></root>"))
        case "/applist": return Self.http(MoonlightHttpReply(status: 200, body: Self.appList))
        case "/launch", "/resume": return Self.http(launch(target))
        case "/cancel": return Self.http(cancel())
        default: return nil
        }
    }

    /// The session key rides the launch; from here on the control port opens
    /// the packets with it. The reply names the RTSP port, as a real host's does.
    private func launch(_ target: String) -> MoonlightHttpReply {
        lock.lock()
        launchTargets.append(target)
        lock.unlock()
        if let rikey = ReferenceMoonlightHost.params(of: target)["rikey"].flatMap(hexDecode) { control.adopt(rikey: rikey) }
        let body = "<root status_code=\"200\"><sessionUrl0>rtsp://127.0.0.1:\(rtsp.port)</sessionUrl0><gamesession>1</gamesession></root>"
        return MoonlightHttpReply(status: 200, body: body)
    }

    private func cancel() -> MoonlightHttpReply {
        lock.lock()
        cancels += 1
        lock.unlock()
        return MoonlightHttpReply(status: 200, body: "<root status_code=\"200\"><cancel>1</cancel></root>")
    }

    private func serverInfo(pairStatus: Int) -> MoonlightHttpReply {
        let body = "<root status_code=\"200\"><hostname>\(Self.hostName)</hostname><uniqueid>\(Self.uniqueId)</uniqueid>"
            + "<HttpsPort>\(securePort)</HttpsPort><ExternalPort>\(plainPort)</ExternalPort><PairStatus>\(pairStatus)</PairStatus>"
            + "<currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>"
        return MoonlightHttpReply(status: 200, body: body)
    }

    private static func http(_ reply: MoonlightHttpReply) -> MoonlightLoopbackServer.Answer {
        MoonlightLoopbackServer.httpAnswer(status: reply.status, body: reply.body)
    }
}
