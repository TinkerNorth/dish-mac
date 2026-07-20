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

import CryptoKit
import Foundation
import Network

/// Close-notify reasons (contract §UDP messages, opcode 0x000F).
enum FakeSatelliteCloseReason: UInt8 {
    case shutdown = 0
    case kicked = 1
    case replaced = 2
    case unpaired = 3
}

/// Protocol-1 UDP opcodes. Topology opcodes 0x0004–0x0008 and 0x000E are
/// DELETED by the contract (REST-only topology) and deliberately absent.
enum FakeSatelliteOpcode {
    static let input: UInt16 = 0x0001
    static let heartbeat: UInt16 = 0x0002
    static let heartbeatAck: UInt16 = 0x0003
    static let rumble: UInt16 = 0x0009
    static let motion: UInt16 = 0x000A
    static let battery: UInt16 = 0x000B
    static let touchpad: UInt16 = 0x000C
    static let lightbar: UInt16 = 0x000D
    static let sessionClose: UInt16 = 0x000F
}

/// Parsed 16-byte touchpad payload (contract §0x000C), including the
/// trailing eventTimeMs u32 LE at offset 12.
struct FakeSatelliteTouchpadFrame: Equatable {
    let ctrlIdx: UInt8
    let flags: UInt8
    let finger0Id: UInt8
    let finger0X: Int16
    let finger0Y: Int16
    let finger1Id: UInt8
    let finger1X: Int16
    let finger1Y: Int16
    let eventTimeMs: UInt32
}

/// One successfully decrypted uplink frame, typed where the opcode is known.
struct FakeSatelliteFrame {
    enum Detail: Equatable {
        case heartbeat
        case input(ctrlIdx: UInt8, report: Data)
        case motion(ctrlIdx: UInt8, gyro: [Int16], accel: [Int16], timestampDeltaUs: UInt32)
        case battery(ctrlIdx: UInt8, level: UInt8, status: UInt8)
        case touchpad(FakeSatelliteTouchpadFrame)
        case unknown
    }

    let opcode: UInt16
    let counter: UInt32
    let payload: Data
    let detail: Detail

    static func parseDetail(opcode: UInt16, payload: Data) -> Detail {
        let base = payload.startIndex
        switch opcode {
        case FakeSatelliteOpcode.heartbeat:
            return .heartbeat
        case FakeSatelliteOpcode.input where payload.count == 13:
            return .input(ctrlIdx: payload[base], report: Data(payload.dropFirst()))
        case FakeSatelliteOpcode.motion where payload.count == 17:
            let gyro = (0 ..< 3).map { Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 1 + $0 * 2)) }
            let accel = (0 ..< 3).map { Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 7 + $0 * 2)) }
            return .motion(
                ctrlIdx: payload[base],
                gyro: gyro,
                accel: accel,
                timestampDeltaUs: FakeSatelliteCrypto.readLE32(payload, at: 13)
            )
        case FakeSatelliteOpcode.battery where payload.count == 3:
            return .battery(ctrlIdx: payload[base], level: payload[base + 1], status: payload[base + 2])
        case FakeSatelliteOpcode.touchpad where payload.count == 16:
            return .touchpad(FakeSatelliteTouchpadFrame(
                ctrlIdx: payload[base],
                flags: payload[base + 1],
                finger0Id: payload[base + 2],
                finger0X: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 3)),
                finger0Y: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 5)),
                finger1Id: payload[base + 7],
                finger1X: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 8)),
                finger1Y: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 10)),
                eventTimeMs: FakeSatelliteCrypto.readLE32(payload, at: 12)
            ))
        default:
            return .unknown
        }
    }
}

/// One minted UDP session: token, derived key, per-direction counters and
/// the reply flow learned from the last valid uplink packet. All mutation
/// happens under the store lock.
final class FakeSatelliteSession {
    let token: UInt32
    let key: SymmetricKey
    var lastUpCounter: UInt32 = 0
    var downCounter: UInt32 = 0
    var reply: NWConnection?

    init(token: UInt32, key: SymmetricKey) {
        self.token = token
        self.key = key
    }
}

/// All shared mutable harness state behind one NSCondition: transports and
/// tests mutate/read via `with`, tests block with bounded `wait(timeout:for:)`
/// (no polling sleeps anywhere).
final class FakeSatelliteStore {

    struct State {
        // Trust.
        var pairingKeyHex: String?
        var pairedDeviceId: String?
        var pairedDeviceName: String?
        var lastClientPin: String?
        var stagedApprovalKeyHex: String?
        var clientPinDenied = false
        // Session.
        var sessions: [UInt32: FakeSatelliteSession] = [:]
        var activeToken: UInt32?
        var tokenCounter: UInt32 = 7
        var epoch: UInt16 = 1
        var controllers: [[String: Any]] = []
        var lastMouseGranted = false
        var lastSessionSaltHex: String?
        // Knobs.
        var forced401Code: String?
        var protocolVersionReject = false
        var holdNextSessionPut = false
        var heldSessionPuts = 0
        var ackEpochOverride: UInt16?
        var ackBitmapOverride: UInt16?
        var ackCountOverride: UInt8?
        var ackBackendAvailableOverride: Bool?
        // Records.
        var sessionPuts: [[String: Any]] = []
        var reconcileGets: [String] = []
        var unpairCalls: [String] = []
        var pairStatusPolls = 0
        var heartbeatCount = 0
        var catalogRequests = 0
        var frames: [FakeSatelliteFrame] = []
        var replayDrops = 0
        var authFailDrops = 0
        var unknownTokenDrops = 0
    }

    private let condition = NSCondition()
    private var state = State()

    func with<T>(_ body: (inout State) -> T) -> T {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        return body(&state)
    }

    /// Bounded wait until `predicate` holds; returns its final verdict.
    func wait(timeout: TimeInterval, for predicate: (State) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(state) {
            if !condition.wait(until: deadline) { return predicate(state) }
        }
        return true
    }
}

enum FakeSatelliteRandom {
    static func data(_ count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
    }

    static func hex(_ count: Int) -> String {
        FakeSatelliteCrypto.hexString(data(count))
    }
}

/// Small shared helper: start an NWListener and block (bounded) until it is
/// ready, returning the bound port.
enum FakeSatelliteNet {
    enum Failure: Error {
        case notReady(String)
    }

    static func startAndAwaitReady(_ listener: NWListener, queue: DispatchQueue, timeout: TimeInterval = 5) throws -> UInt16 {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case let .failed(error):
                lock.lock()
                failure = String(describing: error)
                lock.unlock()
                semaphore.signal()
            case .cancelled:
                lock.lock()
                failure = failure ?? "cancelled"
                lock.unlock()
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw Failure.notReady("listener start timed out")
        }
        lock.lock()
        let failed = failure
        lock.unlock()
        if let failed {
            listener.cancel()
            throw Failure.notReady(failed)
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw Failure.notReady("listener has no port")
        }
        return port
    }
}

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
