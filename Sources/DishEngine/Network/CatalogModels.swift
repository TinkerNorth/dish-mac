// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// `GET /api/catalog` DTOs (contract §ServerInfo & Catalog): the virtual
// controller types a satellite offers, each with its features and the pad
// family it emulates. Lenient like the other REST DTOs: a missing field is
// its default, an unknown slug is ignored.

import DishCore
import Foundation

// MARK: - Catalog (contract §ServerInfo & Catalog)

/// `GET /api/catalog` — the virtual controller types a satellite offers
/// (unauthenticated). `catalogVersion` is the catalog's schema version,
/// absent on the legacy two-type catalog; `protocolVersion` is the newest
/// wire version the satellite speaks, absent on a pre-versioning one.
/// Lenient like the other DTOs here.
struct CatalogDTO: Decodable, Equatable {
    var locale = ""
    var protocolVersion = ProtocolConstants.protocolVersionWhenAbsent
    var catalogVersion = ProtocolConstants.catalogVersionWhenAbsent
    var serverVersion = ""
    var controllerTypes: [CatalogControllerType] = []
    var hostFeatures = CatalogHostFeatures()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case locale, protocolVersion, catalogVersion, serverVersion, controllerTypes, hostFeatures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? ""
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? ProtocolConstants.protocolVersionWhenAbsent
        self.catalogVersion = try container.decodeIfPresent(Int.self, forKey: .catalogVersion)
            ?? ProtocolConstants.catalogVersionWhenAbsent
        self.serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        self.controllerTypes = try container.decodeIfPresent(
            [CatalogControllerType].self, forKey: .controllerTypes
        ) ?? []
        self.hostFeatures = try container.decodeIfPresent(CatalogHostFeatures.self, forKey: .hostFeatures)
            ?? CatalogHostFeatures()
    }
}

/// One offered virtual controller type. `id` is the descriptor `type` byte;
/// `emulates` names the physical pad family this type is the natural
/// default for (catalog version 2).
struct CatalogControllerType: Decodable, Equatable {
    var id = Int(ProtocolConstants.controllerTypeXbox)
    var slug = ""
    var name = ""
    var shortName = ""
    var description = ""
    var features = CatalogFeatures()
    var image = CatalogImage()
    var emulates: CatalogEmulates?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, slug, name, shortName, description, features, image, emulates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(Int.self, forKey: .id)
            ?? Int(ProtocolConstants.controllerTypeXbox)
        self.slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.shortName = try container.decodeIfPresent(String.self, forKey: .shortName) ?? ""
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.features = try container.decodeIfPresent(CatalogFeatures.self, forKey: .features) ?? CatalogFeatures()
        self.image = try container.decodeIfPresent(CatalogImage.self, forKey: .image) ?? CatalogImage()
        self.emulates = try container.decodeIfPresent(CatalogEmulates.self, forKey: .emulates)
    }
}

/// The physical-pad identity a type emulates: `sdlType` in the clients'
/// `SDL_GameControllerType` vocabulary (`xbox360`, `ps4`, `ps5`, `switchpro`)
/// and the USB `vendor:product` ids. Protocol constants, never localized. A
/// `usb` list in a shape this client does not know reads as empty rather
/// than failing the whole catalog.
struct CatalogEmulates: Decodable, Equatable {
    var sdlType = ""
    var usb: [String] = []

    init(sdlType: String = "", usb: [String] = []) {
        self.sdlType = sdlType
        self.usb = usb
    }

    private enum CodingKeys: String, CodingKey { case sdlType, usb }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sdlType = try container.decodeIfPresent(String.self, forKey: .sdlType) ?? ""
        self.usb = (try? container.decodeIfPresent([String].self, forKey: .usb)) ?? []
    }
}

/// Per-type feature flags, one per protocol slug. A slug this client does
/// not know is ignored, never an error.
struct CatalogFeatures: Decodable, Equatable {
    var rumble = CatalogFeature()
    var analogTriggers = CatalogFeature()
    var motion = CatalogFeature()
    var lightbar = CatalogFeature()
    var touchpad = CatalogFeature()
    var triggerEffects = CatalogFeature()
    var playerLeds = CatalogFeature()
    var mic = CatalogFeature()
    var speaker = CatalogFeature()
    var hapticAudio = CatalogFeature()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case rumble, analogTriggers, motion, lightbar, touchpad, triggerEffects, playerLeds, mic, speaker, hapticAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func feature(_ key: CodingKeys) throws -> CatalogFeature {
            try container.decodeIfPresent(CatalogFeature.self, forKey: key) ?? CatalogFeature()
        }
        self.rumble = try feature(.rumble)
        self.analogTriggers = try feature(.analogTriggers)
        self.motion = try feature(.motion)
        self.lightbar = try feature(.lightbar)
        self.touchpad = try feature(.touchpad)
        self.triggerEffects = try feature(.triggerEffects)
        self.playerLeds = try feature(.playerLeds)
        self.mic = try feature(.mic)
        self.speaker = try feature(.speaker)
        self.hapticAudio = try feature(.hapticAudio)
    }
}

/// A single `{"supported":Bool}` capability flag, with the optional
/// `modes` a feature offers and the `requires` code behind it.
struct CatalogFeature: Decodable, Equatable {
    var supported = false
    var modes: [String] = []
    var requires: String?

    init(supported: Bool = false, modes: [String] = [], requires: String? = nil) {
        self.supported = supported
        self.modes = modes
        self.requires = requires
    }

    private enum CodingKeys: String, CodingKey { case supported, modes, requires }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        self.modes = try container.decodeIfPresent([String].self, forKey: .modes) ?? []
        self.requires = try nonEmpty(container.decodeIfPresent(String.self, forKey: .requires))
    }
}

/// A type's artwork reference (`{href,etag}`); rendered by the deferred picker.
struct CatalogImage: Decodable, Equatable {
    var href = ""
    var etag = ""

    init() {}

    private enum CodingKeys: String, CodingKey { case href, etag }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.href = try container.decodeIfPresent(String.self, forKey: .href) ?? ""
        self.etag = try container.decodeIfPresent(String.self, forKey: .etag) ?? ""
    }
}

/// Host-level catalog features (`{supported}` shape — distinct from the
/// session response's grant shape). Modeled for fidelity; unused for now.
struct CatalogHostFeatures: Decodable, Equatable {
    var mouseControl = CatalogFeature()
    var keyboardControl = CatalogFeature()
    var rumble = CatalogFeature()

    init() {}

    private enum CodingKeys: String, CodingKey { case mouseControl, keyboardControl, rumble }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mouseControl = try container.decodeIfPresent(CatalogFeature.self, forKey: .mouseControl) ?? CatalogFeature()
        self.keyboardControl = try container.decodeIfPresent(CatalogFeature.self, forKey: .keyboardControl)
            ?? CatalogFeature()
        self.rumble = try container.decodeIfPresent(CatalogFeature.self, forKey: .rumble) ?? CatalogFeature()
    }
}
