// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import dnssd
import Network
import XCTest
@testable import DishEngine

/// The one reading that names a local-network refusal: a flow to the
/// gateway. Off the network there is nothing to refuse; a gateway that never
/// answers is not a refusal either; and this Mac's own gateway admits an
/// allowed process. The classifiers the probe and the browse share are pure.
final class LocalNetworkProbeTests: XCTestCase {

    func testNoGatewayIsNotARefusal() async {
        let denied = await LocalNetworkProbe.isDenied(gateway: nil, timeoutMs: 100)
        XCTAssertFalse(denied)
    }

    func testAGatewayThatNeverAnswersIsNotARefusal() async {
        // TEST-NET-1 routes through the default gateway and answers nothing;
        // a UDP flow to it is still allowed, so the probe reads "not refused".
        let denied = await LocalNetworkProbe.isDenied(gateway: "192.0.2.1", timeoutMs: 1500)
        XCTAssertFalse(denied)
    }

    func testThisMacsGatewayAdmitsAnAllowedProcess() async throws {
        guard let gateway = LocalNetworkProbe.defaultGateway() else { throw XCTSkip("this Mac has no IPv4 default gateway") }
        let denied = await LocalNetworkProbe.isDenied(gateway: gateway)
        XCTAssertFalse(denied, "a test process is allowed on the local network; the probe must agree")
    }

    func testTheDaemonsPolicyRefusalIsALocalNetworkDenialAndOtherErrorsAreNot() {
        XCTAssertTrue(LocalNetworkProbe.isLocalNetworkDenial(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        XCTAssertFalse(LocalNetworkProbe.isLocalNetworkDenial(.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchName))))
        XCTAssertFalse(LocalNetworkProbe.isLocalNetworkDenial(.posix(.ENETDOWN)))
    }

    func testANilPathIsNotADenial() {
        XCTAssertFalse(LocalNetworkProbe.isLocalNetworkDenial(nil))
    }
}
