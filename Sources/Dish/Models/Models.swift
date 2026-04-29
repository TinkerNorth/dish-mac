// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

// MARK: - Server / protocol DTOs (names match Android Models.kt)

struct DiscoveredServer: Codable, Hashable, Identifiable {
    var name = ""
    var ip = ""
    var udpPort = 9876
    var pairPort = 9878
    var httpPort = 9877

    var id: String {
        "wifi:\(ip):\(udpPort)"
    }

    init(
        name: String = "",
        ip: String = "",
        udpPort: Int = 9876,
        pairPort: Int = 9878,
        httpPort: Int = 9877
    ) {
        self.name = name
        self.ip = ip
        self.udpPort = udpPort
        self.pairPort = pairPort
        self.httpPort = httpPort
    }

    /// The satellite server's discovery beacon omits `ip` (the recipient observes
    /// it from the packet source), so the auto-synthesized Decodable — which
    /// fails on any missing key regardless of default values — is replaced with
    /// one that falls back to each field's default when absent. See
    /// `satellite/src/net/discovery.cpp` for the wire format.
    private enum CodingKeys: String, CodingKey {
        case name, ip, udpPort, pairPort, httpPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        self.udpPort = try container.decodeIfPresent(Int.self, forKey: .udpPort) ?? 9876
        self.pairPort = try container.decodeIfPresent(Int.self, forKey: .pairPort) ?? 9878
        self.httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 9877
    }
}

struct PairResponse: Codable {
    var ok = false
    var error: String?
    var sharedKey: String?
}

struct ConnectResponse: Codable {
    var connectionId: String?
    var token: String?
    var error: String?
}

// MARK: - UI-level aggregation (matches ConnectionHub.kt shapes)

enum ConnectionLive { case idle, connecting, connected }

struct ConnectionSummary: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
    let live: ConnectionLive
    let boundSlotId: String?
}

// MARK: - Controller slots (matches MainUiState.kt)

enum SlotInputType { case virtual, physical }

struct ControllerSlot: Identifiable, Hashable {
    let id: String
    let inputType: SlotInputType
    let name: String
    /// Opaque GCController identifier for physical slots; empty for virtual.
    var physicalDeviceId = ""
    var boundConnectionId: String?
    var boundStatus: ConnectionSummary?
}

let virtualSlotID = "virtual"

// MARK: - Persisted remembered connection (matches RememberedWifi)

struct RememberedWifi: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var ip: String
    var udpPort: Int
    var pairPort: Int
    var httpPort: Int

    func toDiscovered() -> DiscoveredServer {
        DiscoveredServer(name: name, ip: ip, udpPort: udpPort, pairPort: pairPort, httpPort: httpPort)
    }
}
