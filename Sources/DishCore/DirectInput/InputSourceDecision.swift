// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Which source a pad's input comes from when it connects: GameController
// (Standard) or Dish's own HID reader (Direct). Nintendo's Direct-by-model
// pads go Direct unless the user sent a Switch Pro that GameController shows
// back to Standard; a pad GameController does not support goes Direct when
// Dish can decode it; everything else stays Standard.

import Foundation

/// The two places a pad's input can come from. The raw values are the
/// fleet's `usb_path_choices` storage tokens.
public enum InputSource: String, CaseIterable, Equatable, Sendable {
    case standard
    case direct

    /// Lenient: an unknown token (one a newer build wrote) is no choice.
    public static func fromStorage(_ token: String?) -> InputSource? {
        token.flatMap(InputSource.init(rawValue:))
    }
}

/// Whether GameController shows the pad: a controller for it, or
/// `GCController.supportsHIDDevice`, which the engine re-checks for a short
/// while after a connect before it settles.
public enum GameControllerSupport: Equatable, Sendable {
    case pending
    case shows
    case doesNotShow
}

/// What the engine knows about a pad when it connects.
public struct PadPathFacts: Equatable, Sendable {
    public var model: DirectModel?
    /// Dish has a decoder for it: a Direct model, or a descriptor that parsed.
    public var decodable: Bool
    public var gameController: GameControllerSupport
    /// The model's stored `usb_path_choices` entry.
    public var stored: InputSource?
    /// GameController's controller for the model fell back to Standard
    /// (`standCarrier`): macOS already reads the pad, for this connection.
    public var fellBackToStandard = false

    public init(model: DirectModel?, decodable: Bool, gameController: GameControllerSupport, stored: InputSource?) {
        self.model = model
        self.decodable = decodable
        self.gameController = gameController
        self.stored = stored
    }

    /// Before a connect: nothing known, nothing decodable.
    public static let unknown = PadPathFacts(model: nil, decodable: false, gameController: .pending, stored: nil)
}

/// The one reason line a card and Diagnostics show for the path.
public enum InputSourceReason: Equatable, Sendable {
    /// A Nintendo pad Dish reads whatever macOS does.
    case directByModel
    /// GameController does not support it and Dish decodes it.
    case macOSCannotRead
    /// GameController reads it.
    case macOSReads
    /// The user's pick, live or stored.
    case userPicked
    /// A Direct-by-model pad Dish's reader had no lane for in time.
    case dishCouldNotRead
}

public enum PathDecision: Equatable, Sendable {
    case forward(InputSource, InputSourceReason)
    /// The answer turns on GameController's support, not settled yet.
    case awaitGameController
    /// Neither path reads it.
    case unreadable
}

public func decidePath(_ facts: PadPathFacts) -> PathDecision {
    switch facts.model?.rule {
    case .byModel: decideByModel(facts)
    case .whenMacOSCannot, nil: decideBySupport(facts)
    }
}

/// A stored Standard is honoured only for a model that offers it, and only
/// while GameController shows the pad; a fallen-back carrier is Standard
/// already.
private func decideByModel(_ facts: PadPathFacts) -> PathDecision {
    let offersStandard = facts.model?.offersStandard == true
    let pickedStandard = facts.stored == .standard && offersStandard
    if facts.fellBackToStandard { return .forward(.standard, pickedStandard ? .userPicked : .dishCouldNotRead) }
    guard pickedStandard else { return .forward(.direct, .directByModel) }
    switch facts.gameController {
    case .pending: return .awaitGameController
    case .shows: return .forward(.standard, .userPicked)
    case .doesNotShow: return .forward(.direct, .directByModel)
    }
}

/// A stored Direct wins for a pad Dish decodes; otherwise GameController's
/// support decides.
private func decideBySupport(_ facts: PadPathFacts) -> PathDecision {
    let pickedDirect = facts.stored == .direct && facts.decodable
    if pickedDirect { return .forward(.direct, .userPicked) }
    switch facts.gameController {
    case .pending: return .awaitGameController
    case .shows: return .forward(.standard, facts.stored == .standard ? .userPicked : .macOSReads)
    case .doesNotShow: return facts.decodable ? .forward(.direct, .macOSCannotRead) : .unreadable
    }
}

/// Whether the user may move the pad onto `source`: Direct needs a decoder,
/// Standard needs GameController to show the pad and the model to allow it.
public func pathAvailable(_ source: InputSource, _ facts: PadPathFacts) -> Bool {
    switch source {
    case .direct: return facts.decodable
    case .standard:
        let shows = facts.gameController == .shows
        let allowed = facts.model?.offersStandard ?? true
        return shows && allowed
    }
}
