// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// `GET /api/server/capabilities`: what the satellite can do right now
/// (contract §ServerInfo). Dynamic, unauthenticated, additive: an older
/// server omits whole blocks and each reads as "not there". Lenient like the
/// other DTOs.
struct ServerCapabilitiesDTO: Decodable, Equatable {
    /// The newest protocol version the satellite speaks; absent means 1.
    var protocolVersion = ProtocolConstants.protocolVersionWhenAbsent
    var serverVersion = ""
    var maxControllers = ProtocolConstants.maxControllersPerConnection
    /// The preferred backend is up enough to accept controllers.
    var backendAvailable = false
    /// The motion backend works right now.
    var motionAvailable = false
    var host = ServerHostFeatures()
    var controllerAudio = ServerControllerAudio()
    /// Client-side: a body arrived.
    var reachable = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, serverVersion, maxControllers, backend, motion, host, controllerAudio
    }

    private struct Availability: Decodable {
        var available: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? ProtocolConstants.protocolVersionWhenAbsent
        self.serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        self.maxControllers = try container.decodeIfPresent(Int.self, forKey: .maxControllers)
            ?? ProtocolConstants.maxControllersPerConnection
        self.backendAvailable = try container.decodeIfPresent(Availability.self, forKey: .backend)?.available ?? false
        self.motionAvailable = try container.decodeIfPresent(Availability.self, forKey: .motion)?.available ?? false
        self.host = try container.decodeIfPresent(ServerHostFeatures.self, forKey: .host) ?? ServerHostFeatures()
        self.controllerAudio = try container.decodeIfPresent(ServerControllerAudio.self, forKey: .controllerAudio)
            ?? ServerControllerAudio()
    }
}

/// One host feature's static `supported` and runtime `available`.
struct ServerHostFeature: Decodable, Equatable {
    var supported = false
    var available = false

    init(supported: Bool = false, available: Bool = false) {
        self.supported = supported
        self.available = available
    }

    private enum CodingKeys: String, CodingKey { case supported, available }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        self.available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
    }
}

/// The receiver's own inventory. `catalog.supported` is the presence signal:
/// a server that emits the block sets it, so a default here means an older
/// satellite.
struct ServerHostFeatures: Decodable, Equatable {
    var catalog = ServerHostFeature()
    var mouseControl = ServerHostFeature()
    var keyboardControl = ServerHostFeature()
    var rumble = ServerHostFeature()

    init() {}

    private enum CodingKeys: String, CodingKey { case catalog, mouseControl, keyboardControl, rumble }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.catalog = try container.decodeIfPresent(ServerHostFeature.self, forKey: .catalog) ?? ServerHostFeature()
        self.mouseControl = try container.decodeIfPresent(ServerHostFeature.self, forKey: .mouseControl) ?? ServerHostFeature()
        self.keyboardControl = try container.decodeIfPresent(ServerHostFeature.self, forKey: .keyboardControl)
            ?? ServerHostFeature()
        self.rumble = try container.decodeIfPresent(ServerHostFeature.self, forKey: .rumble) ?? ServerHostFeature()
    }
}

/// The host's controller-audio switches, each ANDed with `enabled` by the
/// server so a client learns what will actually flow.
struct ServerControllerAudio: Decodable, Equatable {
    var enabled = false
    var mic = false
    var speaker = false
    var hapticAudio = false

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, mic, speaker, hapticAudio }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.mic = try container.decodeIfPresent(Bool.self, forKey: .mic) ?? false
        self.speaker = try container.decodeIfPresent(Bool.self, forKey: .speaker) ?? false
        self.hapticAudio = try container.decodeIfPresent(Bool.self, forKey: .hapticAudio) ?? false
    }
}
