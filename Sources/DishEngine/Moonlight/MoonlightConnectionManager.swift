// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Moonlight host path, the sibling of WifiConnectionManager and the port
// of dish-android's MoonlightConnectionManager: discovery, PIN pairing, the
// probe that says how far a host is trusted, and the session lifecycle as
// the pure reducer's effects run against the HTTP, RTSP and ENet edges.
//
// ONE SESSION PER HOST, OWNED BY THE BINDINGS. `applyDesired` is the whole
// lifecycle: the first pad on a host launches (or resumes) and streams,
// later pads only announce themselves on the live stream, and the last pad
// leaving is what sends /cancel. Nothing else starts or stops a session.
// Everything that opens or closes one runs serialised, so two bindings
// arriving together cannot both decide they are the first pad on a host.

import Combine
import DishCore
import Foundation

/// What the manager tells the app, as data; the app words each case.
enum MoonlightConnectionEvent: Equatable {
    /// The dish minted `pin`; the user types it into the host's own page.
    case pairingPinReady(host: MoonlightHost, pin: String)
    case paired(MoonlightHost)
    /// Pairing ran and did not end in trust; `reason` names which step gave up.
    case pairingFailed(host: MoonlightHost, reason: MoonlightPairingFailure)
    /// The host answered under another uniqueid, so the old pairing is dead.
    case hostReplaced(MoonlightHost)
    /// The host refused to start an app because one is already running; when
    /// `resumable` the dish could take it over, else somebody else's.
    case appAlreadyRunning(host: MoonlightHost, resumable: Bool)
    /// The host said it would hand its session back and then would not.
    case rejoinRefused(MoonlightHost)
    /// The host refused for a reason of its own; `message` is its own wording.
    case launchRefused(host: MoonlightHost, message: String)
    /// The app started and the stream did not come up, so it was cancelled again.
    case setupFailed(MoonlightHost)
    /// The host already carries the four controllers a session can hold.
    case hostFull(MoonlightHost)
    /// The host ended the session; nothing is recoverable without a new one.
    case endedByHost(MoonlightHost)
    /// The dish asked the host to close the app it runs; the host does not say whether it will.
    case appCloseRequested(MoonlightHost)
    case noHostAnswered(address: String)
    case noAppsAvailable(MoonlightHost)
    /// The picked app is no longer on the host's list, so nothing was launched.
    case appRemoved(host: MoonlightHost, appName: String)
}

/// Why a pairing did not end in trust: which phase gave up, how, and the
/// host's own words when it had any.
struct MoonlightPairingFailure: Equatable {
    enum Kind: Equatable {
        /// This device has no identity to pair with: the keychain refused to mint one.
        case noIdentity
        case noCertificate
        case noChallengeResponse
        case noPairingSecret
        /// The host's hash or signature did not verify: a wrong PIN, or not
        /// the host that presented the certificate.
        case hostNotAuthentic
        /// Phase 4 or 5 did not confirm the pairing.
        case notConfirmed
    }

    var phase: Int
    var kind: Kind
    var httpStatus: Int
    var hostSaid: String
}

/// How far a host is trusted, as of the last time it was asked. There is no
/// liveness in this protocol: pairing is one-time trust, the host never says
/// it revoked one, and a mutual-TLS call it answers is the only proof.
enum MoonlightTrustState: Equatable {
    case checking
    case paired
    case notPaired
    case unreachable
    /// A pairing is stored and the host does not answer.
    case remembered
    /// A pairing is stored and the host answered unpaired.
    case trustLost
    /// Another machine answers under the address.
    case replaced
}

struct MoonlightProbe: Equatable {
    var trust: MoonlightTrustState = .checking
    var apps: [MoonlightApp] = []
    var appsFetched = false
    var appsFailed = false
    var currentGame = 0

    /// What a probe of a host forgotten while it was being asked has to say: nothing is held for it.
    static let forgotten = MoonlightProbe(trust: .notPaired)
}

/// One binding's claim on a host session: which slot, and what pad to announce for it.
struct MoonlightPadRequest: Equatable {
    var slotId: String
    var announced: MoonlightAnnouncedPad
}

typealias MoonlightPairingIdentity = MoonlightClientIdentity & MoonlightSignatureVerifier

/// The published state is written here and by the manager's own extensions, never from outside the engine.
@MainActor
final class MoonlightConnectionManager: ObservableObject {
    @Published var connections: [String: MoonlightConnection] = [:]
    @Published var discoveredHosts: [MoonlightHost] = []
    @Published private(set) var isScanning = false
    /// Hosts that answered a mutual-TLS call in this process: the only proof
    /// a pairing stands, so a row can say Paired and not merely Remembered.
    @Published var verifiedHostIds: Set<String> = []
    /// Hosts this device holds a session open for.
    @Published var sessionHostIds: Set<String> = []
    @Published var pairingInFlight: Set<String> = []
    @Published var rememberedHosts: [RememberedMoonlightHost] = []
    /// What each host last said about itself, for the diagnostics.
    @Published var hostFacts: [String: MoonlightServerInfo] = [:]
    let events = PassthroughSubject<MoonlightConnectionEvent, Never>()

    let store: MoonlightHostStore
    let gateway: MoonlightHostGateway
    /// Nil until the keychain has minted one; a pairing before that fails as noIdentity.
    private(set) var identity: MoonlightPairingIdentity?
    let edges: MoonlightSessionEdges
    let discover: () async -> [MoonlightHost]
    let random: (Int) -> Data
    let nonce: () -> String
    lazy var uniqueId: String = store.uniqueId()
    var desired: [String: [MoonlightPadRequest]] = [:]
    /// Bumped by forget, per host: a probe or a pairing notes the one it
    /// started under and writes nothing once it has moved.
    var epochs: [String: Int] = [:]
    var pairingGenerations: [String: Int] = [:]
    var attempts: [String: MoonlightSessionAttempt] = [:]
    private var chain: Task<Void, Never>?

    init(
        store: MoonlightHostStore,
        gateway: MoonlightHostGateway,
        identity: MoonlightPairingIdentity?,
        edges: MoonlightSessionEdges = LiveMoonlightSessionEdges(),
        discover: @escaping () async -> [MoonlightHost] = { await MoonlightDiscovery.discover() },
        random: @escaping (Int) -> Data = { count in Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) }) },
        nonce: @escaping () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.gateway = gateway
        self.identity = identity
        self.edges = edges
        self.discover = discover
        self.random = random
        self.nonce = nonce
        rememberedHosts = store.hosts()
    }

    func get(_ id: String) -> MoonlightConnection? {
        connections[id]
    }

    /// The identity minted off the main thread at launch.
    func adoptIdentity(_ identity: MoonlightPairingIdentity) {
        self.identity = identity
    }

    /// Everything that opens or closes a session runs here, one piece after
    /// another, and a forget waits for a session coming up on its host so it
    /// takes it down with the rest.
    func serialized(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits for everything queued so far: the tests' way to see a converge land.
    func awaitQuiet() async {
        await chain?.value
    }

    // MARK: - Discovery

    /// Browse for hosts and MERGE the answer into what is already known: one
    /// mDNS miss must not erase every host that was only ever discovered,
    /// and a binding pointing at one with it.
    func startDiscovery() {
        guard !isScanning else { return }
        isScanning = true
        let discover = discover
        Task { @MainActor [weak self] in
            let found = await discover()
            self?.finishScan(found)
        }
    }

    private func finishScan(_ found: [MoonlightHost]) {
        discoveredHosts = discoveredHosts.filter { old in !found.contains { $0.id == old.id } } + found
        isScanning = false
    }

    /// Probe a typed address on the default port and add the host when it
    /// answers; typing an address is durable interest, so it is remembered.
    func addManualHost(_ address: String) {
        Task { @MainActor [weak self] in await self?.addManual(address) }
    }

    private func addManual(_ address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = await plainServerInfo(MoonlightEndpoint(address: trimmed)) else {
            events.send(.noHostAnswered(address: trimmed))
            return
        }
        let host = MoonlightHost(
            name: info.hostname.isEmpty ? trimmed : info.hostname,
            address: trimmed,
            httpPort: info.externalPort ?? MoonlightProtocol.httpPort,
            httpsPort: info.httpsPort ?? MoonlightProtocol.httpsPort,
            uniqueId: info.uniqueId,
            manual: true
        )
        mergeDiscovered(host)
        rememberInterest(host)
        keepFirstUniqueId(host.id, info)
    }

    func mergeDiscovered(_ host: MoonlightHost) {
        discoveredHosts = discoveredHosts.filter { $0.id != host.id } + [host]
    }

    // MARK: - The pool

    /// The pool entry for a host, created on first use with its link events
    /// routed back here.
    func findOrCreate(_ host: MoonlightHost) -> MoonlightConnection {
        if let existing = connections[host.id] { return existing }
        let fresh = MoonlightConnection(id: host.id, host: host)
        fresh.setEffectsRunner { [weak self, weak fresh] effects in
            guard let self, let fresh else { return }
            Task { @MainActor in await self.run(effects, on: fresh) }
        }
        connections[host.id] = fresh
        return fresh
    }

    func hostFor(_ hostId: String) -> MoonlightHost? {
        connections[hostId]?.host ?? store.host(id: hostId)?.host ?? discoveredHosts.first { $0.id == hostId }
    }

    func publishSessionHosts() {
        sessionHostIds = Set(connections.values.filter { $0.padCount > 0 && $0.phase != .idle }.map(\.id))
    }

    func epochOf(_ hostId: String) -> Int {
        epochs[hostId] ?? 0
    }

    /// Whether the host was forgotten since its epoch read `epoch`: nothing
    /// read before that is written after it.
    func forgottenSince(_ hostId: String, _ epoch: Int) -> Bool {
        epochOf(hostId) != epoch
    }

    func markVerified(_ hostId: String) {
        verifiedHostIds.insert(hostId)
    }

    func noteFacts(_ hostId: String, _ info: MoonlightServerInfo) {
        hostFacts[hostId] = info
    }
}
