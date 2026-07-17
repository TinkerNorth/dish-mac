// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

// MARK: - Server / protocol DTOs (names match Android Models.kt)

/// Which discovery path surfaced a satellite. mDNS / Bonjour is the modern
/// path; `broadcast` is the legacy UDP beacon; `both` means it answered on
/// each. Not on the wire — assigned client-side by the discovery merge.
enum DiscoverySource: String, Codable, Hashable {
    case broadcast
    case mdns
    case both

    /// Short human label for the connections list.
    var label: String {
        switch self {
        case .broadcast: "UDP broadcast"
        case .mdns: "mDNS"
        case .both: "mDNS + broadcast"
        }
    }
}

struct DiscoveredServer: Codable, Hashable, Identifiable {
    var name = ""
    var ip = ""
    var udpPort = 9876
    /// HTTPS client API port (TLS, self-signed). Pairing and the connection
    /// API now share this single port; mDNS advertises it under both the
    /// `pair` and `http` TXT keys.
    var pairPort = 9443
    var httpPort = 9443
    /// Stable per-install satellite identity from the beacon (`machineId`) /
    /// mDNS TXT (`mid`). Empty for satellites that predate it. Protocol-1
    /// keys remembered satellites on this — never on ip/port — see `id`
    /// (contract §Identity).
    var machineId = ""
    /// Discovery path this server was heard on. Excluded from `CodingKeys`
    /// (not a wire field); stays `.broadcast` when decoded from a beacon.
    var source: DiscoverySource = .broadcast

    /// The stable identity a dish keys a satellite on. Prefers `machineId`
    /// (survives DHCP address changes), falls back to ip:udpPort for older
    /// satellites that don't advertise one. Both discovery paths, the
    /// connection pool and the remembered store key on this, so one physical
    /// receiver collapses to a single entry instead of one row per IP.
    /// Mirrors dish-linux `DiscoveredServer::id()` / dish-android stableKey.
    var id: String {
        machineId.isEmpty ? "wifi:\(ip):\(udpPort)" : "mid:\(machineId)"
    }

    init(
        name: String = "",
        ip: String = "",
        udpPort: Int = 9876,
        pairPort: Int = 9443,
        httpPort: Int = 9443,
        machineId: String = "",
        source: DiscoverySource = .broadcast
    ) {
        self.name = name
        self.ip = ip
        self.udpPort = udpPort
        self.pairPort = pairPort
        self.httpPort = httpPort
        self.machineId = machineId
        self.source = source
    }

    /// The satellite server's discovery beacon omits `ip` (the recipient observes
    /// it from the packet source), so the auto-synthesized Decodable — which
    /// fails on any missing key regardless of default values — is replaced with
    /// one that falls back to each field's default when absent. See
    /// `satellite/src/net/discovery.cpp` for the wire format.
    private enum CodingKeys: String, CodingKey {
        case name, ip, udpPort, pairPort, httpPort, machineId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        self.udpPort = try container.decodeIfPresent(Int.self, forKey: .udpPort) ?? 9876
        self.pairPort = try container.decodeIfPresent(Int.self, forKey: .pairPort) ?? 9443
        self.httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 9443
        self.machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
    }
}

struct PairResponse: Codable {
    var ok = false
    /// Path B: the request is parked awaiting operator approval on the
    /// satellite; poll `GET /api/pair/status` for the outcome (contract
    /// §Pairing).
    var pending = false
    var error: String?
    var sharedKey: String?
    /// Echoed by the server on every pairing response; absent means 1
    /// (contract §Versioning).
    var protocolVersion = 1
    /// HTTP status of the exchange (0 = the transport never produced a
    /// response). Client-side, not on the wire — lets the manager spot a 409
    /// version mismatch without re-reading the body.
    var httpStatus = 0
    /// True iff we received any JSON body from the server. False for synthesized
    /// failure responses (socket / connect / send errors). Not on the wire — the
    /// server never sends this field; it's set client-side by `PairingClient`.
    var reachable = false

    private enum CodingKeys: String, CodingKey { case ok, pending, error, sharedKey, protocolVersion }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        self.pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.sharedKey = try container.decodeIfPresent(String.self, forKey: .sharedKey)
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
    }

    init(
        ok: Bool = false,
        pending: Bool = false,
        error: String? = nil,
        sharedKey: String? = nil,
        protocolVersion: Int = 1,
        httpStatus: Int = 0,
        reachable: Bool = false
    ) {
        self.ok = ok
        self.pending = pending
        self.error = error
        self.sharedKey = sharedKey
        self.protocolVersion = protocolVersion
        self.httpStatus = httpStatus
        self.reachable = reachable
    }
}

// (Protocol-0's `ConnectResponse` is deleted: the session handshake is the
// declarative PUT and its `SessionResponse` DTO in Network/RestModels.swift.)

// MARK: - UI-level aggregation (matches ConnectionHub.kt shapes)

/// UI-facing link state for one connection. This is the chip a row renders;
/// combines the persistent "Pairing" axis (have we paired?) and the live
/// "Presence" axis (do we see it / is the session up?).
///
/// Internally a Satellite session also has `SessionState` (the wire-level
/// presence axis only); `LinkState` is derived from that plus discovery /
/// remembered presence in `ConnectionHub.rebuild`.
///
/// | LinkState   | Pairing axis    | Presence axis    | User-facing chip |
/// |-------------|-----------------|------------------|------------------|
/// | `.found`    | unpaired        | seen             | "Found"          |
/// | `.stale`    | broken (lost)   | any              | "Needs pairing"  |
/// | `.saved`    | paired          | absent           | "Offline"        |
/// | `.ready`    | paired          | seen, no session | "Ready"          |
/// | `.connecting` | paired        | linking          | "Connecting…"    |
/// | `.connected`  | paired        | live             | "Online"         |
/// | `.unstable`   | paired        | faltering/stale  | "Unsteady"       |
///
/// **`.stale`** enters when the satellite revokes trust: a terminal 401
/// (NOT_PAIRED / BAD_PROOF) on any authed route or an authenticated
/// close-notify(unpaired) — both funnel through the manager's
/// `handleTerminalAuth`, which drops only the key and parks the row in the
/// persistent `staleSatelliteIds` set (gaps G6/G15).
///
/// **`.unstable`** enters from `SessionState.faltering` (2 consecutive
/// missed heartbeat acks — contract §Liveness) and from
/// `SessionState.stale`, the death→silent-retry backoff window (gap G15).
enum LinkState { case found, stale, saved, ready, connecting, connected, unstable }

struct ConnectionSummary: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    let live: LinkState
    let boundSlotId: String?
    /// One-way latency readout (median heartbeat RTT ÷ 2, rounded to
    /// 0.1 ms), present only while a session is up and has paired at least
    /// one ack (gap G13).
    var latencyMs: Double?
}

// MARK: - Controller capabilities + battery (UX surface)

/// What a physical controller's *hardware* exposes, detected once at attach.
/// Distinct from `FeatureSettings`, which is whether the *user* wants each
/// feature forwarded. The slot card shows capabilities as chips so the player
/// can see at a glance that, e.g., their DualSense's gyro was detected — the
/// "gyro detected" feedback every comparable tool (DS4Windows, Steam Input)
/// surfaces.
struct ControllerCapabilities: Hashable {
    var hasMotion = false
    var hasTouchpad = false
    var hasRumble = false
    /// The controller has an addressable RGB light bar (`GCController.light`).
    /// Drives the "Lightbar" capability chip and the `capLightbar` bit in the
    /// REST controller descriptor's caps word.
    var hasLightbar = false
    var hasBattery = false

    static let none = ControllerCapabilities()
}

/// Charging state for the slot-card battery pill. Maps from
/// `GCDeviceBattery.State`; the raw wire value is in `SatelliteClient`.
enum BatteryChargeState: Hashable {
    case unknown, discharging, charging, full
}

/// Live battery reading shown in the slot card. `level` is 0...100, or nil
/// when the controller reports state but not a percentage.
struct BatteryReading: Hashable {
    var level: Int?
    var state: BatteryChargeState = .unknown
}

// MARK: - Controller slots (matches MainUiState.kt)

struct ControllerSlot: Identifiable, Hashable {
    let id: String
    let name: String
    var boundConnectionId: String?
    var boundStatus: ConnectionSummary?
    /// Hardware capabilities detected at attach.
    var capabilities: ControllerCapabilities = .none
    /// Most recent battery reading, nil until the first sample arrives.
    var battery: BatteryReading?
}

// MARK: - Persisted remembered connection (matches RememberedWifi)

struct RememberedWifi: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var ip: String
    var udpPort: Int
    var pairPort: Int
    var httpPort: Int
    /// Persisted machineId so a remembered satellite that changes IP keeps its
    /// identity (`id` is already the machineId-preferring stable key). Empty
    /// for rows persisted before protocol-1 — they still load (see the lenient
    /// decoder) and are upgraded in place by `ConnectionStore.remember` the
    /// first time the box is seen with a stable id.
    var machineId: String

    init(
        id: String,
        name: String,
        ip: String,
        udpPort: Int,
        pairPort: Int,
        httpPort: Int,
        machineId: String = ""
    ) {
        self.id = id
        self.name = name
        self.ip = ip
        self.udpPort = udpPort
        self.pairPort = pairPort
        self.httpPort = httpPort
        self.machineId = machineId
    }

    /// Rows persisted before protocol-1 lack `machineId`; the synthesized
    /// decoder would reject them wholesale, silently forgetting every saved
    /// satellite on upgrade. Fall back to "" instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.ip = try container.decode(String.self, forKey: .ip)
        self.udpPort = try container.decode(Int.self, forKey: .udpPort)
        self.pairPort = try container.decode(Int.self, forKey: .pairPort)
        self.httpPort = try container.decode(Int.self, forKey: .httpPort)
        self.machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
    }

    func toDiscovered() -> DiscoveredServer {
        DiscoveredServer(
            name: name,
            ip: ip,
            udpPort: udpPort,
            pairPort: pairPort,
            httpPort: httpPort,
            machineId: machineId
        )
    }
}
