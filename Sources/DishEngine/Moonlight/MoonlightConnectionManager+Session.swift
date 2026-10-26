// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One attempt at a host's session, from the first probe to the teardown:
/// what the launch settled and minted, and where the stream stands.
final class MoonlightSessionAttempt {
    var probe = MoonlightProbe()
    var appId = ""
    var appName = ""
    var rikey = Data()
    var rikeyId: Int32 = 0
    var rtsp: MoonlightRtspStepping?
    var session: MoonlightLiveSession?
    var pinger: MoonlightMediaPinger?
    /// The host started an app on our behalf.
    var launched = false
    var wentLive = false
    /// The stop came from the last pad leaving a live session.
    var lastPadLeftLive = false
    /// The host's own words on its last refusal.
    var hostMessage = ""
}

/// The session lifecycle: the bindings' desire converged onto one session
/// per host, and the reducer's effects run against the edges.
extension MoonlightConnectionManager {
    static let rikeyLength = 16

    /// Converge every host's session on the pads its bindings ask for: the
    /// only entry point into the lifecycle. A host that gains its first pad
    /// is launched, a host that keeps pads only gains and loses them on the
    /// live stream, and a host that loses its last pad is cancelled.
    func applyDesired(_ desired: [String: [MoonlightPadRequest]]) {
        self.desired = desired
        converge()
    }

    /// The retry behind every failed-session action: nothing about the
    /// bindings changed, only another attempt at what already is.
    func retrySessions() {
        converge()
    }

    private func converge() {
        let desired = self.desired
        serialized { [weak self] in await self?.convergeAll(desired) }
    }

    private func convergeAll(_ desired: [String: [MoonlightPadRequest]]) async {
        for (hostId, pads) in desired.sorted(by: { $0.key < $1.key }) where !pads.isEmpty {
            await convergeHost(hostId, pads)
        }
        let wanted = Set(desired.filter { !$0.value.isEmpty }.keys)
        for hostId in connections.keys.sorted() where !wanted.contains(hostId) {
            await releaseHost(hostId)
        }
        publishSessionHosts()
    }

    private func convergeHost(_ hostId: String, _ pads: [MoonlightPadRequest]) async {
        guard let host = hostFor(hostId) else { return }
        let conn = findOrCreate(host)
        conn.updateHost(host)
        let wanted = Set(pads.map(\.slotId))
        for pad in conn.pads where !wanted.contains(pad.slotId) {
            _ = conn.releasePad(pad.slotId)
        }
        switch moonlightConverge(phase: conn.phase, wantedPads: wanted.count) {
        case .wait:
            break
        case .open:
            placePads(conn, host, pads)
            await openStream(conn, host)
        case .announce:
            placePads(conn, host, pads)
        case .release, .cancel:
            await releaseHost(hostId)
        }
    }

    /// Every requested pad placed. A held pad asked for as another pad
    /// (another type, or motion bits it was not announced with) is
    /// re-announced; one that finds no room is the user's to hear about.
    private func placePads(_ conn: MoonlightConnection, _ host: MoonlightHost, _ pads: [MoonlightPadRequest]) {
        for pad in pads {
            switch MoonlightPadRules.placement(held: conn.pad(for: pad.slotId)?.announced, wanted: pad.announced) {
            case .acquire:
                if conn.acquirePad(pad.slotId, as: pad.announced) == nil { events.send(.hostFull(host)) }
            case .reannounce:
                _ = conn.reannouncePad(pad.slotId, as: pad.announced)
            case .keep:
                break
            }
        }
    }

    /// The last pad left: the session is stopped, and a live one hands its app back.
    private func releaseHost(_ hostId: String) async {
        guard let conn = connections[hostId] else { return }
        attempts[hostId]?.lastPadLeftLive = conn.isStreaming
        for pad in conn.pads {
            _ = conn.releasePad(pad.slotId)
        }
        await run(conn.apply(.stopRequested), on: conn)
    }

    /// Stop a host's session for the user and keep its pads claimed: the
    /// app is left running (a resume is the next session's to ask for), and
    /// the next converge opens again.
    func disconnect(hostId: String) {
        serialized { [weak self] in
            guard let self, let conn = connections[hostId] else { return }
            await run(conn.apply(.stopRequested), on: conn)
            publishSessionHosts()
        }
    }

    /// The machine is about to sleep: every session stops the way a user's
    /// disconnect stops it, its pads still claimed and the app left running,
    /// so the wake's converge opens it again and resumes.
    func stopSessionsForSleep() {
        for hostId in connections.keys.sorted() {
            disconnect(hostId: hostId)
        }
    }

    /// Tell the host to end the app it runs: the protocol's own way out of
    /// "an app is already running" when the host will not resume it for us.
    /// /cancel answers 200 whether or not anything ran, so nothing is believed from it.
    func quitHostApp(_ host: MoonlightHost) {
        serialized { [weak self] in await self?.quitNow(host) }
    }

    private func quitNow(_ host: MoonlightHost) async {
        if let conn = connections[host.id] {
            attempts[host.id]?.launched = false
            for pad in conn.pads {
                _ = conn.releasePad(pad.slotId)
            }
            await run(conn.apply(.stopRequested), on: conn)
        }
        _ = await cancelHostApp(host)
        publishSessionHosts()
        events.send(.appCloseRequested(host))
    }

    func cancelHostApp(_ host: MoonlightHost) async -> Bool {
        let reply = await gateway.getSecure(MoonlightUrls.cancel(host.endpoint, uniqueId: uniqueId, nonce: nonce()), hostId: host.id)
        return reply.ok && MoonlightXml.status(reply.body)?.ok != false
    }

    // MARK: - The reducer's effects

    private func openStream(_ conn: MoonlightConnection, _ host: MoonlightHost) async {
        attempts[host.id] = MoonlightSessionAttempt()
        await run(conn.apply(.startRequested), on: conn)
    }

    /// Run the effects one reduction asked for, in order; each may raise the next event.
    func run(_ effects: [MoonlightSessionEffect], on conn: MoonlightConnection) async {
        for effect in effects {
            await perform(effect, on: conn)
        }
    }

    private func perform(_ effect: MoonlightSessionEffect, on conn: MoonlightConnection) async {
        switch effect {
        case .fetchServerInfo:
            let event = await serverInfoEvent(conn)
            await run(conn.apply(event), on: conn)
        case .sendLaunch:
            let event = await launchEvent(conn)
            await run(conn.apply(event), on: conn)
        case .openRtsp:
            // One connection per message: there is nothing to open ahead of the first.
            await run(conn.apply(.rtspReady), on: conn)
        case let .sendRtsp(step):
            let ok = await attempts[conn.id]?.rtsp?.perform(step, config: MoonlightStreamConfig()) ?? false
            await run(conn.apply(ok ? .rtspStepOk : .rtspFailed), on: conn)
        case .connectControl:
            let event = await connectControl(conn)
            await run(conn.apply(event), on: conn)
        case .startStreaming:
            startStreaming(conn)
        case .sendTermination:
            conn.sendTermination()
        case .teardown:
            await teardown(conn)
        case .notifyFailure:
            notifyFailure(conn)
        }
    }

    /// The probe, re-run immediately before a session opens: the pairing is
    /// remembered trust, and the host may have dropped it or come back as
    /// another machine since anything last asked.
    private func serverInfoEvent(_ conn: MoonlightConnection) async -> MoonlightSessionEvent {
        let host = conn.host
        let probe = await probe(host)
        attempts[host.id]?.probe = probe
        let remembered = store.host(id: host.id)?.paired == true
        switch probe.trust {
        case .paired: return .serverInfoOk(paired: true, remembered: remembered, identityChanged: false)
        case .replaced: return .serverInfoOk(paired: true, remembered: true, identityChanged: true)
        case .trustLost: return .serverInfoOk(paired: false, remembered: true, identityChanged: false)
        case .notPaired: return .serverInfoOk(paired: false, remembered: false, identityChanged: false)
        case .unreachable, .remembered, .checking: return .serverInfoFailed
        }
    }

    /// The app settled once per attempt, then /launch, or /resume once the
    /// host offered it. A MOONLIGHT HOST REFUSES IN THE BODY, NOT IN THE
    /// STATUS LINE: a second /launch is answered HTTP 200 with status_code
    /// 400 and "An app is already running on this host".
    private func launchEvent(_ conn: MoonlightConnection) async -> MoonlightSessionEvent {
        let host = conn.host
        guard let attempt = attempts[host.id] else { return .launchFailed }
        if attempt.appId.isEmpty, let refusal = settleApp(attempt, host: host) { return refusal }
        let launch = MoonlightLaunchRequest(appId: attempt.appId, rikey: attempt.rikey, rikeyId: attempt.rikeyId)
        let request = conn.machine.resuming
            ? MoonlightUrls.resume(host.endpoint, uniqueId: uniqueId, launch: launch, nonce: nonce())
            : MoonlightUrls.launch(host.endpoint, uniqueId: uniqueId, launch: launch, nonce: nonce())
        let reply = await gateway.getSecure(request, hostId: host.id)
        let status = MoonlightXml.status(reply.body)
        attempt.hostMessage = status?.message ?? ""
        let launched = MoonlightXml.launchReply(reply.body)
        if reply.ok, status?.ok != false, let launched, launched.sessionUrl != nil || launched.launched {
            attempt.rtsp = edges.rtspClient(address: host.address, port: launched.rtspPort)
            attempt.launched = true
            return .launchOk
        }
        if let status, status.appAlreadyRunning { return .launchBusy(resumable: status.resume) }
        return .launchFailed
    }

    /// The remembered pick, else the first app the host lists, with the keys
    /// minted; nil once settled, else why nothing can launch. A pick the host
    /// no longer lists launches nothing and stays the pick: it is the user's
    /// to change.
    private func settleApp(_ attempt: MoonlightSessionAttempt, host: MoonlightHost) -> MoonlightSessionEvent? {
        let remembered = store.host(id: host.id)
        let pick = remembered?.lastAppId ?? ""
        let pickedName = (remembered?.lastAppName).flatMap { $0.isEmpty ? nil : $0 }
        let apps = attempt.probe.apps
        if !pick.isEmpty, attempt.probe.appsFetched, !apps.contains(where: { $0.id == pick }) {
            attempt.appName = pickedName ?? pick
            return .pickedAppRemoved
        }
        guard let appId = pick.isEmpty ? apps.first?.id : pick else { return .noAppsAvailable }
        attempt.appId = appId
        attempt.appName = pickedName ?? apps.first { $0.id == appId }?.title ?? ""
        attempt.rikey = random(Self.rikeyLength)
        attempt.rikeyId = Self.rikeyId(from: random(4))
        return nil
    }

    /// Four random bytes read little-endian as a signed number, as real clients send it.
    static func rikeyId(from bytes: Data) -> Int32 {
        var value: UInt32 = 0
        for (index, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * UInt32(index))
        }
        return Int32(bitPattern: value)
    }

    /// The media ports pinged before the control channel, not after: the host
    /// counts its initial-ping deadline from its own session start.
    private func connectControl(_ conn: MoonlightConnection) async -> MoonlightSessionEvent {
        let host = conn.host
        guard let attempt = attempts[host.id], let ports = attempt.rtsp?.negotiated else { return .controlLost }
        let pinger = edges.mediaPinger(address: host.address, ports: ports)
        pinger.start()
        attempt.pinger = pinger
        let session = await edges.connectControl(
            address: host.address,
            ports: ports,
            rikey: attempt.rikey,
            onEvent: { event in conn.receive(event) },
            onClosed: { conn.linkClosed() }
        )
        guard let session else {
            pinger.stop()
            attempt.pinger = nil
            return .controlLost
        }
        attempt.session = session
        return .controlConnected
    }

    private func startStreaming(_ conn: MoonlightConnection) {
        let host = conn.host
        guard let attempt = attempts[host.id], let session = attempt.session else { return }
        conn.adopt(session: session, pinger: attempt.pinger, appId: attempt.appId, appName: attempt.appName)
        attempt.wentLive = true
        rememberPaired(host, appId: attempt.appId, appName: attempt.appName, paired: true)
        publishSessionHosts()
    }

    /// The clocks, the pings and the session stopped. The app is handed back
    /// when the host started it for us and nobody rides it: a setup that
    /// failed after the launch, or the last pad leaving a live session. A
    /// drop, or the host's own ending, leaves the app alone: a drop is as
    /// likely a blip as an end, and closing somebody's game is worse than
    /// the tidying is worth.
    private func teardown(_ conn: MoonlightConnection) async {
        let host = conn.host
        conn.teardown()
        defer { publishSessionHosts() }
        guard let attempt = attempts[host.id] else { return }
        attempt.session = nil
        attempt.pinger = nil
        attempt.rtsp = nil
        let handBack = shouldHandBackApp(
            launched: attempt.launched,
            wentLive: attempt.wentLive,
            lastControllerLeft: attempt.lastPadLeftLive
        )
        guard handBack else { return }
        attempt.launched = false
        _ = await cancelHostApp(host)
    }

    /// Which refusal the failure is, for the user; the trust verdicts the row already shows, and a drop, say nothing more.
    private func notifyFailure(_ conn: MoonlightConnection) {
        let host = conn.host
        guard case let .failed(reason) = conn.phase else { return }
        let attempt = attempts[host.id]
        switch reason {
        case .hostReplaced: events.send(.hostReplaced(host))
        case .appAlreadyRunning: events.send(.appAlreadyRunning(host: host, resumable: false))
        case .resumeFailed: events.send(.rejoinRefused(host))
        case .launchRejected: events.send(.launchRefused(host: host, message: attempt?.hostMessage ?? ""))
        case .rtspRejected, .controlLost: events.send(.setupFailed(host))
        case .noApps: events.send(.noAppsAvailable(host))
        case .appRemoved: events.send(.appRemoved(host: host, appName: attempt?.appName ?? ""))
        case .hostEnded: events.send(.endedByHost(host))
        case .unreachable, .notPaired, .trustLost, .dropped: break
        }
    }
}
