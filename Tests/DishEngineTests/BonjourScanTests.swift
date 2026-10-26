// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Network
import XCTest
@testable import DishEngine

/// The Bonjour browse's promise beyond what it found: the address it hands
/// back is the IPv4 one even when the host also answers over IPv6. The round
/// trip stands up a dual-stack host on this Mac's mDNS daemon and resolves it
/// through `BonjourScan`; a Mac whose daemon never confirms it skips.
final class BonjourScanTests: XCTestCase {

    func testTheResolvingConnectionAsksForIPv4Only() {
        let params = BonjourScan.resolveParameters()
        let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        XCTAssertEqual(ip?.version, .v4)
    }

    func testADualStackHostIsHandedBackByItsIPv4Address() async throws {
        let host = try ProxiedDualStackHost()
        defer { host.stop() }
        guard await host.advertised(within: 5) else { throw XCTSkip("the mDNS daemon did not confirm the proxied host") }

        let outcome = await BonjourScan.discover(serviceType: host.serviceType, txtKeys: [], timeoutMs: 4000) { name, address, _ in
            (id: name, found: address)
        }

        if outcome.localNetworkDenied { throw XCTSkip("macOS refuses this process the local network") }
        XCTAssertEqual(
            outcome.found,
            [ProxiedDualStackHost.ipv4],
            "a resolver that takes whichever address answers first lands on \(ProxiedDualStackHost.ipv6) and is dropped"
        )
    }
}
