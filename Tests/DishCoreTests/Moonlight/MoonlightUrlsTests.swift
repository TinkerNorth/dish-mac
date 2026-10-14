// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The requests, port by port and parameter by parameter.
final class MoonlightUrlsTests: XCTestCase {

    private let host = MoonlightEndpoint(address: "192.168.1.20", httpPort: 47989, httpsPort: 47984)

    func testServerInfoRidesPlainOrTlsOnThePortServerInfoNamed() {
        let plain = MoonlightUrls.serverInfo(host, tls: false, uniqueId: "0123456789abcdef", nonce: "n1")
        XCTAssertEqual(
            plain,
            MoonlightHttpRequest(
                host: "192.168.1.20",
                port: 47989,
                tls: false,
                pathAndQuery: "/serverinfo?uniqueid=0123456789abcdef&uuid=n1"
            )
        )
        let secure = MoonlightUrls.serverInfo(
            MoonlightEndpoint(address: "pc.local", httpPort: 1, httpsPort: 47990),
            tls: true,
            uniqueId: "u",
            nonce: "n2"
        )
        XCTAssertEqual(secure.port, 47990)
        XCTAssertTrue(secure.tls)
    }

    func testPairCarriesThePhaseParamsThenTheNonce() {
        let request = MoonlightUrls.pair(host, tls: false, params: [("devicename", "roth"), ("phrase", "getservercert")], nonce: "n")
        XCTAssertEqual(request.pathAndQuery, "/pair?devicename=roth&phrase=getservercert&uuid=n")
        XCTAssertFalse(request.tls)
        XCTAssertTrue(MoonlightUrls.pair(host, tls: true, params: [], nonce: "n").tls, "phase 5 rides the TLS port")
    }

    func testLaunchAsksForTheLowestStreamAndStereo() {
        // A plain pattern for the key: the secret scanner reads a 32-hex key in
        // a URL as a leaked credential, and the shape is all this pins.
        let launch = MoonlightLaunchRequest(appId: "881448767", rikey: Data(repeating: 0x5A, count: 16), rikeyId: -24_495_799)
        let request = MoonlightUrls.launch(host, uniqueId: "u", launch: launch, nonce: "n")
        XCTAssertEqual(
            request.pathAndQuery,
            "/launch?uniqueid=u&appid=881448767&mode=1280x720x30&additionalStates=1&sops=0&rikey=5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"
                + "&rikeyid=-24495799&localAudioPlayMode=1&surroundAudioInfo=196610&uuid=n"
        )
        XCTAssertTrue(request.tls)
        XCTAssertEqual(request.port, 47984)
    }

    func testResumeAndCancelCarryOnlyWhatTheyNeed() {
        let launch = MoonlightLaunchRequest(appId: "1", rikey: Data(count: 16), rikeyId: 7)
        XCTAssertEqual(
            MoonlightUrls.resume(host, uniqueId: "u", launch: launch, nonce: "n").pathAndQuery,
            "/resume?uniqueid=u&rikey=00000000000000000000000000000000&rikeyid=7&surroundAudioInfo=196610&uuid=n"
        )
        XCTAssertEqual(MoonlightUrls.cancel(host, uniqueId: "u", nonce: "n").pathAndQuery, "/cancel?uniqueid=u&uuid=n")
        XCTAssertEqual(MoonlightUrls.appList(host, uniqueId: "u", nonce: "n").pathAndQuery, "/applist?uniqueid=u&uuid=n")
    }

    func testFormEncodingIsTheFormKind() {
        XCTAssertEqual(MoonlightUrls.formEncode("a b/c?d=é&f"), "a+b%2Fc%3Fd%3D%C3%A9%26f")
        XCTAssertEqual(MoonlightUrls.formEncode("ok.-*_09AZaz"), "ok.-*_09AZaz")
        XCTAssertEqual(MoonlightUrls.query([("k", "v w"), ("x", "1")]), "k=v+w&x=1")
    }
}
