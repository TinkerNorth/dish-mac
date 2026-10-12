// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// FakeSatellite — an in-process protocol-1 satellite for integration tests,
// the Swift port of dish-android's androidTest FakeSatellite harness.
//
// It implements the client-visible contract surface (satellite
// docs/contract.md): PIN pairing (paths A and B), hmacProof validation, the
// declarative session PUT/GET with per-slot routes, self-unpair, catalog and
// capabilities probes, and the encrypted UDP data plane with enriched
// heartbeat acks, replay guard and close-notify / rumble / lightbar
// injection. Each instance mints its own self-signed certificate at runtime,
// so two instances present different certs: pin one, then connect the other
// under the same identity to exercise TOFU rejection.

import Foundation
import XCTest

/// Facade tying the REST and UDP servers together — this is the surface
/// integration tests program against.
final class FakeSatellite {

    enum Transport {
        case https
        case http
    }

    struct Ports {
        let rest: UInt16
        let udp: UInt16
    }

    let operatorPin: String
    let machineId: String
    let connectionId = "conn_fake01"
    let identity: FakeSatelliteIdentity

    private let store = FakeSatelliteStore()
    private let udp: FakeSatelliteUdp
    private let rest: FakeSatelliteRest
    private(set) var ports: Ports?

    private static let instanceLock = NSLock()
    private static var instanceCount = 0

    private static func nextInstanceNumber() -> Int {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        instanceCount += 1
        return instanceCount
    }

    init(operatorPin: String = "1234", machineId: String? = nil) throws {
        let number = Self.nextInstanceNumber()
        self.operatorPin = operatorPin
        self.machineId = machineId ?? "fake-sat-\(number)"
        identity = try FakeSatelliteCertificateMint.mint(commonName: "fake-satellite-\(number)")
        udp = FakeSatelliteUdp(store: store)
        rest = FakeSatelliteRest(
            store: store,
            identity: identity,
            udp: udp,
            operatorPin: operatorPin,
            connectionId: connectionId
        )
    }

    @discardableResult
    func start() throws -> Ports {
        let udpPort = try udp.start()
        let restPort = try rest.start()
        let ports = Ports(rest: restPort, udp: udpPort)
        self.ports = ports
        return ports
    }

    func stop() {
        rest.stop()
        udp.stop()
    }

    // MARK: - Identity / transport (TOFU material)

    var transport: Transport {
        rest.transport
    }

    /// The app's REST clients are https-only; on a keychain-refusing runner
    /// the harness falls back to plain HTTP and every one of their requests
    /// would fail as a misleading "unreachable". Call from `setUpWithError`
    /// of suites that drive the app clients — a targeted skip, not a
    /// vacuous pass.
    func requireHTTPSTransport() throws {
        if transport != .https {
            throw XCTSkip(
                "FakeSatellite has no SecIdentity on this runner (plain-HTTP fallback); the app's https-only clients cannot reach it"
            )
        }
    }

    var certificateDER: Data {
        identity.certificateDER
    }

    var certificateFingerprintSHA256Hex: String {
        identity.fingerprintSHA256Hex
    }

    // MARK: - Knobs

    /// Settable so tests can pre-pair without the PIN dance.
    var pairingKeyHex: String? {
        get { store.with { $0.pairingKeyHex } }
        set { store.with { $0.pairingKeyHex = newValue } }
    }

    /// Path B: operator approves the pending client PIN; the status poll then
    /// hands the staged key back exactly once (single-use, per contract).
    func approveClientPin() {
        store.with {
            $0.stagedApprovalKeyHex = FakeSatelliteRandom.hex(32)
            $0.clientPinDenied = false
        }
    }

    /// Path B: operator denies the pending client PIN.
    func denyClientPin() {
        store.with {
            $0.stagedApprovalKeyHex = nil
            $0.clientPinDenied = true
        }
    }

    /// Force the next authed REST calls to 401 with this machine code
    /// ("NOT_PAIRED" / "BAD_PROOF"); nil restores normal auth.
    var forced401Code: String? {
        get { store.with { $0.forced401Code } }
        set { store.with { $0.forced401Code = newValue } }
    }

    /// Force 409 protocol-version rejection on pair + session PUT.
    var protocolVersionReject: Bool {
        get { store.with { $0.protocolVersionReject } }
        set { store.with { $0.protocolVersionReject = newValue } }
    }

    /// One-shot: process the next session PUT normally but park its response
    /// until `releaseHeldSessionPut()` — an in-flight re-PUT whose result the
    /// client has not seen yet.
    var holdNextSessionPut: Bool {
        get { store.with { $0.holdNextSessionPut } }
        set { store.with { $0.holdNextSessionPut = newValue } }
    }

    /// Number of session-PUT responses ever parked by the hold knob. Poll
    /// with an async wait — a blocking wait on the main actor would starve
    /// the main-actor flow driving the PUT.
    var heldSessionPutCount: Int {
        store.with { $0.heldSessionPuts }
    }

    @discardableResult
    func releaseHeldSessionPut() -> Bool {
        rest.releaseHeldSessionPut()
    }

    /// One-shot hold for POST /api/pair — parks the caller inside its submit
    /// await so a supersede/cancel deterministically lands mid-flight.
    var holdNextPair: Bool {
        get { store.with { $0.holdNextPair } }
        set { store.with { $0.holdNextPair = newValue } }
    }

    var heldPairCount: Int {
        store.with { $0.heldPairs }
    }

    @discardableResult
    func releaseHeldPair() -> Bool {
        rest.releaseHeldPair()
    }

    /// Overrides for the enriched heartbeat ack (and, for epoch, the
    /// reconcile GET too) — nil means "derived from real state".
    var ackEpochOverride: UInt16? {
        get { store.with { $0.ackEpochOverride } }
        set { store.with { $0.ackEpochOverride = newValue } }
    }

    var ackBitmapOverride: UInt16? {
        get { store.with { $0.ackBitmapOverride } }
        set { store.with { $0.ackBitmapOverride = newValue } }
    }

    var ackCountOverride: UInt8? {
        get { store.with { $0.ackCountOverride } }
        set { store.with { $0.ackCountOverride = newValue } }
    }

    var ackBackendAvailableOverride: Bool? {
        get { store.with { $0.ackBackendAvailableOverride } }
        set { store.with { $0.ackBackendAvailableOverride = newValue } }
    }

    /// Simulates a server-side applied-topology change (contract: epoch
    /// increments on every applied change regardless of initiator).
    func bumpEpoch() {
        store.with { $0.epoch &+= 1 }
    }

    /// contract §hmacProof: "503 means the server is shutting down (retry
    /// later is acceptable)". Answered on the session PUT before auth, like
    /// the real `g_appRunning` guard.
    var shuttingDown: Bool {
        get { store.with { $0.shuttingDown } }
        set { store.with { $0.shuttingDown = newValue } }
    }

    /// Per-controller apply-failure knob: every requested descriptor draws
    /// this result code (`noSlots`/`pluginFailed`/`replugFailed`/
    /// `backendUnavailable`/`invalidType`) instead of applying. nil = apply
    /// normally.
    var controllerApplyFailure: String? {
        get { store.with { $0.controllerApplyFailure } }
        set { store.with { $0.controllerApplyFailure = newValue } }
    }

    /// The admin surface unplugging a slot behind the client's back (the
    /// loopback-9877 analogue): the slot drops and the epoch moves, with no
    /// client-authed HTTP involved.
    func adminUnplugController(ctrlIdx: Int) {
        store.with { state in
            let before = state.controllers.count
            state.controllers.removeAll { ($0["ctrlIdx"] as? Int ?? -1) == ctrlIdx }
            if state.controllers.count != before { state.epoch &+= 1 }
        }
    }

    // MARK: - Downlink injection (encrypted with the active session key)

    @discardableResult
    func sendSessionClose(_ reason: FakeSatelliteCloseReason) -> Bool {
        udp.sendToActive(opcode: FakeSatelliteOpcode.sessionClose, payload: Data([reason.rawValue]))
    }

    @discardableResult
    func injectRumble(ctrlIdx: UInt8, strong: UInt16, weak weakMagnitude: UInt16, durationMs: UInt16) -> Bool {
        let payload = Data([ctrlIdx])
            + FakeSatelliteCrypto.be16(strong)
            + FakeSatelliteCrypto.be16(weakMagnitude)
            + FakeSatelliteCrypto.be16(durationMs)
        return udp.sendToActive(opcode: FakeSatelliteOpcode.rumble, payload: payload)
    }

    @discardableResult
    func injectLightbar(ctrlIdx: UInt8, red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        udp.sendToActive(opcode: FakeSatelliteOpcode.lightbar, payload: Data([ctrlIdx, red, green, blue]))
    }

    // MARK: - State inspection

    var epoch: UInt16 {
        store.with { $0.epoch }
    }

    var lastTokenHex: String? {
        store.with { state in state.activeToken.map { String(format: "%08x", $0) } }
    }

    var lastSessionSaltHex: String? {
        store.with { $0.lastSessionSaltHex }
    }

    var pairedDeviceId: String? {
        store.with { $0.pairedDeviceId }
    }

    var pairedDeviceName: String? {
        store.with { $0.pairedDeviceName }
    }

    var lastClientPin: String? {
        store.with { $0.lastClientPin }
    }

    var appliedControllers: [[String: Any]] {
        store.with { $0.controllers }
    }

    var sessionPuts: [[String: Any]] {
        store.with { $0.sessionPuts }
    }

    var reconcileGets: [String] {
        store.with { $0.reconcileGets }
    }

    var unpairCalls: [String] {
        store.with { $0.unpairCalls }
    }

    var pairStatusPolls: Int {
        store.with { $0.pairStatusPolls }
    }

    var heartbeatCount: Int {
        store.with { $0.heartbeatCount }
    }

    var catalogRequests: Int {
        store.with { $0.catalogRequests }
    }

    var frames: [FakeSatelliteFrame] {
        store.with { $0.frames }
    }

    var replayDrops: Int {
        store.with { $0.replayDrops }
    }

    var authFailDrops: Int {
        store.with { $0.authFailDrops }
    }

    var unknownTokenDrops: Int {
        store.with { $0.unknownTokenDrops }
    }

    // MARK: - Bounded waits (no sleeps)

    func awaitFrame(opcode: UInt16, timeout: TimeInterval = 5) -> FakeSatelliteFrame? {
        var found: FakeSatelliteFrame?
        _ = store.wait(timeout: timeout) { state in
            found = state.frames.first { $0.opcode == opcode }
            return found != nil
        }
        return found
    }

    func awaitFrameCount(opcode: UInt16, atLeast: Int, timeout: TimeInterval = 5) -> Bool {
        store.wait(timeout: timeout) { state in
            state.frames.filter { $0.opcode == opcode }.count >= atLeast
        }
    }

    func awaitHeartbeats(atLeast: Int, timeout: TimeInterval = 5) -> Bool {
        store.wait(timeout: timeout) { $0.heartbeatCount >= atLeast }
    }

    func awaitReplayDrops(atLeast: Int, timeout: TimeInterval = 5) -> Bool {
        store.wait(timeout: timeout) { $0.replayDrops >= atLeast }
    }

    func awaitAuthFailDrops(atLeast: Int, timeout: TimeInterval = 5) -> Bool {
        store.wait(timeout: timeout) { $0.authFailDrops >= atLeast }
    }

    func awaitUnknownTokenDrops(atLeast: Int, timeout: TimeInterval = 5) -> Bool {
        store.wait(timeout: timeout) { $0.unknownTokenDrops >= atLeast }
    }
}
