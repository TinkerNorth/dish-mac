// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// How the manager talks to a host: plain HTTP for /serverinfo and pairing
/// phases 1 to 4, mutual TLS for everything a paired client is answered on.
/// The gateway in production; a scripted one in the manager's tests.
protocol MoonlightHostGateway: AnyObject {
    func getPlain(_ request: MoonlightHttpRequest, timeout: TimeInterval) async -> MoonlightHttpReply
    func getSecure(_ request: MoonlightHttpRequest, hostId: String) async -> MoonlightHttpReply
    func getSecureTrusting(_ request: MoonlightHttpRequest, certificateDER: Data) async -> MoonlightHttpReply
    func pinProven(hostId: String, certificateDER: Data)
    func forgetPin(hostId: String)
}

extension MoonlightGateway: MoonlightHostGateway {}
