// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Why a connect, pair or converge attempt failed, as data. The engine never
/// words a failure; the app localizes each case. `detail` carries text the
/// satellite itself sent, which is shown as-is.
package enum ConnectionFailure: Equatable {
    /// The satellite's TLS certificate differs from the one pinned on first
    /// contact: a reinstall, or an imposter. Only forget-and-pair recovers.
    case identityChanged
    /// A 409 whose range this client could not read; neither end is blamed.
    case protocolMismatch
    /// The satellite's oldest protocol is newer than this app speaks.
    case dishUpdateRequired
    /// The satellite's newest protocol is older than this app's floor.
    case satelliteUpdateRequired
    /// The operator declined the client-PIN request on the satellite.
    case approvalDeclined
    /// The client-PIN request expired before the operator answered.
    case approvalTimedOut
    /// The satellite no longer recognizes this device (terminal 401, or a
    /// close-notify with the `unpaired` reason). A fresh pairing is needed.
    case repairNeeded
    /// No HTTPS response at all; `detail` is the transport's own description.
    case unreachable(detail: String)
    /// A connect was asked for without a stored pairing key.
    case noSharedKey
    /// The session PUT answered without a grant; `detail` is the body's
    /// `error` string when there was one.
    case sessionRefused(detail: String?)
    /// The grant carried malformed token or salt hex.
    case badSessionMaterial
    /// The grant was fine but the UDP socket would not open.
    case sessionLinkFailed
    /// The satellite could not plug the bound controller.
    case controllerNotApplied
    /// A scan found no satellite on the network.
    case noServersFound
    /// A PIN pairing was refused; `detail` is the satellite's `error` string.
    case pairingRejected(detail: String?)
}
