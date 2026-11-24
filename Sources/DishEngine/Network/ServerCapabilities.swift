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
    /// The block was in the body: an older satellite omits it, which reads
    /// as unknown rather than off.
    var controllerAudioPresent = false
    /// Some listed backend is available and builds audio personas.
    var anyBackendAudio = false
    /// The `backends` array as the satellite listed it, for the bundle's
    /// stand-in when the host cannot speak for itself.
    var backendRows: JSONValue?
    /// Client-side: a body arrived.
    var reachable = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, serverVersion, maxControllers, backend, backends, motion, host, controllerAudio
    }

    private struct Availability: Decodable {
        var available: Bool?
    }

    private struct BackendRow: Decodable {
        var available: Bool?
        var audio: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? ProtocolConstants.protocolVersionWhenAbsent
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        maxControllers = try container.decodeIfPresent(Int.self, forKey: .maxControllers)
            ?? ProtocolConstants.maxControllersPerConnection
        backendAvailable = try container.decodeIfPresent(Availability.self, forKey: .backend)?.available ?? false
        motionAvailable = try container.decodeIfPresent(Availability.self, forKey: .motion)?.available ?? false
        host = try container.decodeIfPresent(ServerHostFeatures.self, forKey: .host) ?? ServerHostFeatures()
        let audio = try container.decodeIfPresent(ServerControllerAudio.self, forKey: .controllerAudio)
        controllerAudio = audio ?? ServerControllerAudio()
        controllerAudioPresent = audio != nil
        let backends = (try? container.decodeIfPresent([BackendRow].self, forKey: .backends)) ?? []
        anyBackendAudio = backends.contains { ($0.available ?? false) && ($0.audio ?? false) }
        backendRows = try? container.decodeIfPresent(JSONValue.self, forKey: .backends)
    }

    /// What the host will carry of the pad's audio, folded as the fleet
    /// folds it.
    var audioVerdict: HostAudioVerdict {
        hostAudioVerdict(
            blockPresent: controllerAudioPresent,
            enabled: controllerAudio.enabled,
            mic: controllerAudio.mic,
            speaker: controllerAudio.speaker,
            hapticAudio: controllerAudio.hapticAudio,
            anyBackendAudio: anyBackendAudio
        )
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
        supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
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
        catalog = try container.decodeIfPresent(ServerHostFeature.self, forKey: .catalog) ?? ServerHostFeature()
        mouseControl = try container.decodeIfPresent(ServerHostFeature.self, forKey: .mouseControl) ?? ServerHostFeature()
        keyboardControl = try container.decodeIfPresent(ServerHostFeature.self, forKey: .keyboardControl)
            ?? ServerHostFeature()
        rumble = try container.decodeIfPresent(ServerHostFeature.self, forKey: .rumble) ?? ServerHostFeature()
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
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mic = try container.decodeIfPresent(Bool.self, forKey: .mic) ?? false
        speaker = try container.decodeIfPresent(Bool.self, forKey: .speaker) ?? false
        hapticAudio = try container.decodeIfPresent(Bool.self, forKey: .hapticAudio) ?? false
    }
}

/// What the probe and the catalog said, as the bundle's stand-in reads it.
func satelliteCapabilitiesFacts(_ probe: ServerCapabilitiesDTO, catalog: CatalogDTO?) -> SatelliteCapabilitiesFacts {
    let audio = probe.controllerAudio
    return SatelliteCapabilitiesFacts(
        serverVersion: probe.serverVersion,
        protocolVersion: probe.protocolVersion,
        backends: probe.backendRows,
        controllerAudio: probe.controllerAudioPresent
            ? HostAudioBlock(enabled: audio.enabled, mic: audio.mic, speaker: audio.speaker, hapticAudio: audio.hapticAudio)
            : nil,
        catalogVersion: catalog?.catalogVersion
    )
}
