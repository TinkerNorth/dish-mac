// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import DishCore
import Foundation

// MARK: - Server / protocol DTOs (names match Android Models.kt)

/// Which discovery path surfaced a satellite. mDNS / Bonjour is the modern
/// path; `broadcast` is the legacy UDP beacon; `both` means it answered on
/// each. Not on the wire — assigned client-side by the discovery merge.
package enum DiscoverySource: String, Codable, Hashable {
    case broadcast
    case mdns
    case both
    /// Typed in by the user (`DiscoveredServer.manual`) — the escape hatch
    /// when Local Network permission is denied or the LAN drops multicast.
    case manual
}

package struct DiscoveredServer: Codable, Hashable, Identifiable {
    package var name = ""
    package var ip = ""
    package var udpPort = 9876
    /// HTTPS client API port (TLS, self-signed). Pairing and the connection
    /// API now share this single port; mDNS advertises it under both the
    /// `pair` and `http` TXT keys.
    package var pairPort = 9443
    package var httpPort = 9443
    /// Stable per-install satellite identity from the beacon (`machineId`) /
    /// mDNS TXT (`mid`). Empty for satellites that predate it. Protocol-1
    /// keys remembered satellites on this — never on ip/port — see `id`
    /// (contract §Identity).
    package var machineId = ""
    /// Discovery path this server was heard on. Excluded from `CodingKeys`
    /// (not a wire field); stays `.broadcast` when decoded from a beacon.
    package var source: DiscoverySource = .broadcast

    /// The stable identity a dish keys a satellite on. Prefers `machineId`
    /// (survives DHCP address changes), falls back to ip:udpPort for older
    /// satellites that don't advertise one. Both discovery paths, the
    /// connection pool and the remembered store key on this, so one physical
    /// receiver collapses to a single entry instead of one row per IP.
    /// Mirrors dish-linux `DiscoveredServer::id()` / dish-android stableKey.
    package var id: String {
        machineId.isEmpty ? "wifi:\(ip):\(udpPort)" : "mid:\(machineId)"
    }

    package init(
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

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        self.udpPort = try container.decodeIfPresent(Int.self, forKey: .udpPort) ?? 9876
        self.pairPort = try container.decodeIfPresent(Int.self, forKey: .pairPort) ?? 9443
        self.httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 9443
        self.machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
    }

    /// Manual "add by address" entry — the escape hatch when discovery is
    /// dead (Local Network permission denied, multicast-blocked LAN): an
    /// IPv4 literal with an optional `:udpPort`, seeding the legacy
    /// `wifi:<ip>:<port>` identity the pool and store already support. Nil
    /// on anything else — the UDP data plane dials IPv4 literals only
    /// (`inet_pton`), exactly like the discovery beacon's `ip`.
    package static func manual(from input: String) -> DiscoveredServer? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let host: String
        var udpPort = 9876
        switch parts.count {
        case 1:
            host = String(parts[0])
        case 2:
            guard let port = Int(parts[1]), (1 ... 65535).contains(port) else { return nil }
            host = String(parts[0])
            udpPort = port
        default:
            return nil
        }
        var addr = in_addr()
        guard !host.isEmpty, host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return DiscoveredServer(name: "", ip: host, udpPort: udpPort, source: .manual)
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
    var protocolVersion = ProtocolConstants.protocolVersionWhenAbsent
    /// A 409 body's range (`supported`, `supportedMin`); 0 when absent.
    var supportedProtocol = 0
    var supportedProtocolMin = 0
    /// HTTP status of the exchange (0 = the transport never produced a
    /// response). Client-side, not on the wire — lets the manager spot a 409
    /// version mismatch without re-reading the body.
    var httpStatus = 0
    /// True iff we received any JSON body from the server. False for synthesized
    /// failure responses (socket / connect / send errors). Not on the wire — the
    /// server never sends this field; it's set client-side by `PairingClient`.
    var reachable = false

    private enum CodingKeys: String, CodingKey {
        case ok, pending, error, sharedKey, protocolVersion
        case supportedProtocol = "supported"
        case supportedProtocolMin = "supportedMin"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        self.pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.sharedKey = try container.decodeIfPresent(String.self, forKey: .sharedKey)
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? ProtocolConstants.protocolVersionWhenAbsent
        self.supportedProtocol = try container.decodeIfPresent(Int.self, forKey: .supportedProtocol) ?? 0
        self.supportedProtocolMin = try container.decodeIfPresent(Int.self, forKey: .supportedProtocolMin) ?? 0
    }

    init(
        ok: Bool = false,
        pending: Bool = false,
        error: String? = nil,
        sharedKey: String? = nil,
        protocolVersion: Int = ProtocolConstants.protocolVersionWhenAbsent,
        httpStatus: Int = 0,
        reachable: Bool = false,
        supportedProtocol: Int = 0,
        supportedProtocolMin: Int = 0
    ) {
        self.ok = ok
        self.pending = pending
        self.error = error
        self.sharedKey = sharedKey
        self.protocolVersion = protocolVersion
        self.httpStatus = httpStatus
        self.reachable = reachable
        self.supportedProtocol = supportedProtocol
        self.supportedProtocolMin = supportedProtocolMin
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
package enum LinkState { case found, stale, saved, ready, connecting, connected, unstable }

package struct ConnectionSummary: Identifiable, Hashable {
    package let id: String
    package let label: String
    package let detail: String
    package let live: LinkState
    package let boundSlotId: String?
    /// One-way latency readout (median heartbeat RTT ÷ 2, rounded to
    /// 0.1 ms), present only while a session is up and has paired at least
    /// one ack (gap G13).
    package var latencyMs: Double?
    /// What the last negotiation said about the satellite's protocol version.
    package var compat: ProtocolCompat
    /// The kind of link, for the tier cue. Every host here is a satellite.
    package var kind: ConnectionKind

    package init(
        id: String,
        label: String,
        detail: String,
        live: LinkState,
        boundSlotId: String?,
        latencyMs: Double? = nil,
        compat: ProtocolCompat = .unknown,
        kind: ConnectionKind = .satellite
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.live = live
        self.boundSlotId = boundSlotId
        self.latencyMs = latencyMs
        self.compat = compat
        self.kind = kind
    }
}

// MARK: - Controller capabilities + battery (UX surface)

/// What a physical controller's *hardware* exposes, detected once at attach.
/// Distinct from `FeatureSettings`, which is whether the *user* wants each
/// feature forwarded. The slot card shows capabilities as chips so the player
/// can see at a glance that, e.g., their DualSense's gyro was detected — the
/// "gyro detected" feedback every comparable tool (DS4Windows, Steam Input)
/// surfaces.
package struct ControllerCapabilities: Hashable {
    package var hasMotion = false
    package var hasTouchpad = false
    package var hasRumble = false
    /// The controller has an addressable RGB light bar (`GCController.light`).
    /// Drives the "Lightbar" capability chip and the `capLightbar` bit in the
    /// REST controller descriptor's caps word.
    package var hasLightbar = false
    package var hasBattery = false
    /// The pad takes the DualSense adaptive-trigger effects.
    package var hasTriggerEffects = false
    /// The pad has player-indicator LEDs the framework drives by player index.
    package var hasPlayerLeds = false

    package init(
        hasMotion: Bool = false,
        hasTouchpad: Bool = false,
        hasRumble: Bool = false,
        hasLightbar: Bool = false,
        hasBattery: Bool = false,
        hasTriggerEffects: Bool = false,
        hasPlayerLeds: Bool = false
    ) {
        self.hasMotion = hasMotion
        self.hasTouchpad = hasTouchpad
        self.hasRumble = hasRumble
        self.hasLightbar = hasLightbar
        self.hasBattery = hasBattery
        self.hasTriggerEffects = hasTriggerEffects
        self.hasPlayerLeds = hasPlayerLeds
    }

    package static let none = ControllerCapabilities()
}

/// Charging state for the slot-card battery pill. Maps from
/// `GCDeviceBattery.State`; the raw wire value is in `SatelliteClient`.
package enum BatteryChargeState: Hashable {
    case unknown, discharging, charging, full
}

/// Live battery reading shown in the slot card. `level` is 0...100, or nil
/// when the controller reports state but not a percentage.
package struct BatteryReading: Hashable {
    package var level: Int?
    package var state: BatteryChargeState = .unknown

    package init(level: Int? = nil, state: BatteryChargeState = .unknown) {
        self.level = level
        self.state = state
    }
}

// MARK: - Controller slots (matches MainUiState.kt)

package struct ControllerSlot: Identifiable, Hashable {
    package let id: String
    package let name: String
    package var boundConnectionId: String?
    package var boundStatus: ConnectionSummary?
    /// Hardware capabilities detected at attach.
    package var capabilities: ControllerCapabilities = .none
    /// Most recent battery reading, nil until the first sample arrives.
    package var battery: BatteryReading?
    /// How a bound slot is emulated and what else it could be; nil unbound.
    package var emulation: SlotEmulation?
    /// What the emulated type carries; nil until the catalog is read.
    package var typeFeatures: TypeFeatureFacts?
    /// What the bound satellite carries; nil until its probe is read.
    package var hostProbe: HostProbeFacts?
    /// The satellite's word on this binding's motion; nil before an apply.
    package var motionStatus: MotionBackendStatus?
    /// The controller's own switches, beneath the global ones.
    package var preferences = SlotPreferences()

    package init(
        id: String,
        name: String,
        boundConnectionId: String? = nil,
        boundStatus: ConnectionSummary? = nil,
        capabilities: ControllerCapabilities = .none,
        battery: BatteryReading? = nil,
        emulation: SlotEmulation? = nil,
        typeFeatures: TypeFeatureFacts? = nil,
        hostProbe: HostProbeFacts? = nil,
        motionStatus: MotionBackendStatus? = nil,
        preferences: SlotPreferences = SlotPreferences()
    ) {
        self.id = id
        self.name = name
        self.boundConnectionId = boundConnectionId
        self.boundStatus = boundStatus
        self.capabilities = capabilities
        self.battery = battery
        self.emulation = emulation
        self.typeFeatures = typeFeatures
        self.hostProbe = hostProbe
        self.motionStatus = motionStatus
        self.preferences = preferences
    }
}

// MARK: - Persisted remembered connection (matches RememberedWifi)

package struct RememberedWifi: Codable, Hashable, Identifiable {
    package let id: String
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
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.ip = try container.decode(String.self, forKey: .ip)
        self.udpPort = try container.decode(Int.self, forKey: .udpPort)
        self.pairPort = try container.decode(Int.self, forKey: .pairPort)
        self.httpPort = try container.decode(Int.self, forKey: .httpPort)
        self.machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
    }

    package func toDiscovered() -> DiscoveredServer {
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
