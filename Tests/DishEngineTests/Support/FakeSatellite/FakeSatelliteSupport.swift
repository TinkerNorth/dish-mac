// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The fixture's shared vocabulary: opcodes, parsed frames, the minted
// session, the locked store every transport mutates, and the listener helper.

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
    static let triggerEffects: UInt16 = 0x0010
    static let playerLeds: UInt16 = 0x0011
    static let micAudio: UInt16 = 0x0012
    static let speakerAudio: UInt16 = 0x0013
    static let micLed: UInt16 = 0x0014
    static let hapticAudio: UInt16 = 0x0015
}

/// Parsed 16-byte touchpad payload (contract §0x000C, version 1), including
/// the trailing eventTimeMs u32 LE at offset 12.
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

/// Parsed 19-byte POINTER payload (contract §0x000C, version 2): the click
/// moved into a buttons byte and a signed wheel was appended.
struct FakeSatellitePointerFrame: Equatable {
    let ctrlIdx: UInt8
    let fingerFlags: UInt8
    let buttons: UInt8
    let finger0Id: UInt8
    let finger0X: Int16
    let finger0Y: Int16
    let finger1Id: UInt8
    let finger1X: Int16
    let finger1Y: Int16
    let eventTimeMs: UInt32
    let scrollV: Int16
}

/// One successfully decrypted uplink frame, typed where the opcode is known.
struct FakeSatelliteFrame {
    enum Detail: Equatable {
        case heartbeat
        case input(ctrlIdx: UInt8, report: Data)
        case motion(ctrlIdx: UInt8, gyro: [Int16], accel: [Int16], timestampDeltaUs: UInt32)
        case battery(ctrlIdx: UInt8, level: UInt8, status: UInt8)
        case touchpad(FakeSatelliteTouchpadFrame)
        case pointer(FakeSatellitePointerFrame)
        case micAudio(ctrlIdx: UInt8, seq: UInt16, opus: Data)
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
            return .touchpad(touchpadFrame(payload))
        case FakeSatelliteOpcode.touchpad where payload.count == 19:
            return .pointer(pointerFrame(payload))
        case FakeSatelliteOpcode.micAudio where payload.count > 3:
            let seq = UInt16(payload[base + 1]) << 8 | UInt16(payload[base + 2])
            return .micAudio(ctrlIdx: payload[base], seq: seq, opus: Data(payload.dropFirst(3)))
        default:
            return .unknown
        }
    }

    private static func touchpadFrame(_ payload: Data) -> FakeSatelliteTouchpadFrame {
        let base = payload.startIndex
        return FakeSatelliteTouchpadFrame(
            ctrlIdx: payload[base],
            flags: payload[base + 1],
            finger0Id: payload[base + 2],
            finger0X: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 3)),
            finger0Y: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 5)),
            finger1Id: payload[base + 7],
            finger1X: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 8)),
            finger1Y: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 10)),
            eventTimeMs: FakeSatelliteCrypto.readLE32(payload, at: 12)
        )
    }

    private static func pointerFrame(_ payload: Data) -> FakeSatellitePointerFrame {
        let base = payload.startIndex
        return FakeSatellitePointerFrame(
            ctrlIdx: payload[base],
            fingerFlags: payload[base + 1],
            buttons: payload[base + 2],
            finger0Id: payload[base + 3],
            finger0X: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 4)),
            finger0Y: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 6)),
            finger1Id: payload[base + 8],
            finger1X: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 9)),
            finger1Y: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 11)),
            eventTimeMs: FakeSatelliteCrypto.readLE32(payload, at: 13),
            scrollV: Int16(bitPattern: FakeSatelliteCrypto.readLE16(payload, at: 17))
        )
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
        /// Knobs.
        var forced401Code: String?
        /// The range the fake accepts (contract §Versioning); the real
        /// satellite's is [1, 3].
        var supportedProtocolMin = 1
        var supportedProtocol = 3
        /// The version the last accepted offer settled on, echoed back.
        var settledProtocolVersion = 1
        /// Every offer the range refused, in order.
        var rejectedOffers: [Int] = []
        var holdNextSessionPut = false
        var heldSessionPuts = 0
        var holdNextPair = false
        var heldPairs = 0
        var shuttingDown = false
        var controllerApplyFailure: String?
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
