// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Dish couldn't read it directly, so macOS reads it". A controller
// GameController lists under a Direct-by-model category is only an output
// carrier while Dish's own reader has a lane of its model; one that has
// waited the settle window with no such lane (a pad the reader missed, a
// Bluetooth pad that did not match) is read through GameController instead,
// and stays so for the connection: a lane that turns up later moves nothing
// until a reconnect or the user's pick.

import Foundation

public enum CarrierFallbackRule {
    /// From the controller's arrival.
    public static let settleMs = 2000
}

/// Where a carrier stands on the input paths for its connection.
public enum CarrierStanding: Equatable, Sendable {
    /// No lane of its model yet and the window still open: it publishes nothing.
    case waiting
    /// A lane of its model was there in time: the lanes' machines decide.
    case followsLanes
    /// The window closed with no lane of its model: GameController reads it.
    case fellBack
}

/// Sticky once it leaves `waiting`; a lane seen at the deadline still counts.
public func standCarrier(_ standing: CarrierStanding, lanesOfModel: Int, windowClosed: Bool) -> CarrierStanding {
    guard standing == .waiting else { return standing }
    if lanesOfModel > 0 { return .followsLanes }
    return windowClosed ? .fellBack : .waiting
}
