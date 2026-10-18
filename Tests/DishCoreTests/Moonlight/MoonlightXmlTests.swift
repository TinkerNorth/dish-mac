// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// What a host answers, read the way a host means it: the root's verdict
/// first, then the fields, from bodies captured off a live Sunshine.
final class MoonlightXmlTests: XCTestCase {

    /// Verbatim off Sunshine 7.1: one line, fields in the order it really sends them.
    private let sunshineServerInfo = """
    <?xml version="1.0" encoding="utf-8"?>
    <root status_code="200"><hostname>Samus Aran</hostname><appversion>7.1.431.-1</appversion>\
    <GfeVersion>3.23.0.74</GfeVersion><uniqueid>61651FD7-3927-3E2E-FD1A-6464FCEDE28F</uniqueid>\
    <HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort>\
    <mac>00:00:00:00:00:00</mac><LocalIP>192.168.68.98</LocalIP>\
    <ServerCodecModeSupport>2032385</ServerCodecModeSupport><PairStatus>0</PairStatus>\
    <currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>
    """

    func testParsesARealSunshineServerInfo() throws {
        let info = try XCTUnwrap(MoonlightXml.serverInfo(sunshineServerInfo))
        XCTAssertEqual(info.hostname, "Samus Aran")
        XCTAssertEqual(info.uniqueId, "61651FD7-3927-3E2E-FD1A-6464FCEDE28F")
        XCTAssertEqual(info.httpsPort, 47984)
        XCTAssertEqual(info.externalPort, 47989)
        XCTAssertEqual(info.localIp, "192.168.68.98")
        XCTAssertEqual(info.appVersion, "7.1.431.-1")
        XCTAssertEqual(info.gfeVersion, "3.23.0.74")
        XCTAssertFalse(info.paired)
        XCTAssertFalse(info.busy)
        XCTAssertEqual(MoonlightXml.status(sunshineServerInfo), MoonlightStatus(code: 200, message: "", resume: false))
    }

    func testBusyAndPairedReadFromTheirFields() throws {
        let busy = try XCTUnwrap(MoonlightXml
            .serverInfo("<root><PairStatus>1</PairStatus><currentgame>7</currentgame><state>SUNSHINE_SERVER_BUSY</state></root>"))
        XCTAssertTrue(busy.paired)
        XCTAssertTrue(busy.busy)
        let free = try XCTUnwrap(MoonlightXml.serverInfo("<root><state>SUNSHINE_SERVER_FREE</state></root>"))
        XCTAssertFalse(free.busy)
        XCTAssertNil(free.httpsPort, "absent, never assumed")
    }

    /// Byte for byte what a live Sunshine answered a second /launch with, over HTTP 200.
    func testARefusalIsReadOutOfTheBodyNotTheStatusLine() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<root status_code=\"400\" status_message=\"An app is already running on this host\"><resume>0</resume></root>"
        let status = try XCTUnwrap(MoonlightXml.status(xml))
        XCTAssertEqual(status.code, 400)
        XCTAssertEqual(status.message, "An app is already running on this host")
        XCTAssertFalse(status.ok)
        XCTAssertTrue(status.appAlreadyRunning)
        XCTAssertFalse(status.resume)
        let resumable = try XCTUnwrap(MoonlightXml
            .status("<root status_code=\"400\" status_message=\"An app is already running on this host\"><resume>1</resume></root>"))
        XCTAssertTrue(resumable.appAlreadyRunning)
        XCTAssertTrue(resumable.resume)
    }

    func testNoStatusCodeIsSuccessAndAGarbledOneIsNot() {
        XCTAssertEqual(MoonlightXml.status("<root><App><ID>1</ID></App></root>")?.ok, true, "Wolf's plain /applist")
        let garbled = MoonlightXml.status("<root status_code=\"yes\"></root>")
        XCTAssertEqual(garbled?.code, MoonlightStatus.unreadable)
        XCTAssertEqual(garbled?.ok, false)
        XCTAssertNil(MoonlightXml.status("<root status_code=\"200\">"), "not XML")
        XCTAssertNil(MoonlightXml.status(""))
    }

    func testPairRepliesCarryWhicheverFieldThePhaseHas() throws {
        let phase1 = try XCTUnwrap(MoonlightXml
            .pairReply("<root status_code=\"200\"><paired>1</paired><plaincert>2d2d2d2d2d</plaincert></root>"))
        XCTAssertTrue(phase1.paired)
        XCTAssertEqual(phase1.plainCert, "2d2d2d2d2d")
        XCTAssertNil(phase1.challengeResponse)
        XCTAssertNil(phase1.statusMessage)
        let refused = try XCTUnwrap(MoonlightXml
            .pairReply("<root status_code=\"401\" status_message=\"Incorrect PIN\"><paired>0</paired></root>"))
        XCTAssertFalse(refused.paired)
        XCTAssertEqual(refused.statusMessage, "Incorrect PIN")
        let phase3 = try XCTUnwrap(MoonlightXml.pairReply("<root><paired>1</paired><pairingsecret>abcd</pairingsecret></root>"))
        XCTAssertEqual(phase3.pairingSecret, "abcd")
    }

    func testTheAppListAndTheLaunchReply() throws {
        let apps = MoonlightXml.appList(
            "<root status_code=\"200\"><App><IsHdrSupported>0</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>881448767</ID></App>"
                + "<App><IsHdrSupported>1</IsHdrSupported><AppTitle>Steam Big Picture</AppTitle><ID>1093255277</ID></App>"
                + "<App><AppTitle>no id</AppTitle></App></root>"
        )
        XCTAssertEqual(apps, [
            MoonlightApp(id: "881448767", title: "Desktop", hdrSupported: false),
            MoonlightApp(id: "1093255277", title: "Steam Big Picture", hdrSupported: true)
        ])
        XCTAssertEqual(MoonlightXml.appList("<root></root>"), [])
        XCTAssertEqual(MoonlightXml.appList("garbage"), [])
        let launched = try XCTUnwrap(MoonlightXml
            .launchReply(
                "<root status_code=\"200\"><sessionUrl0>rtsp://192.168.68.98:48010</sessionUrl0><gamesession>1</gamesession></root>"
            ))
        XCTAssertTrue(launched.launched)
        XCTAssertEqual(launched.rtspPort, 48010)
        let noPort = try XCTUnwrap(MoonlightXml
            .launchReply("<root><sessionUrl0>rtsp://192.168.68.98</sessionUrl0><gamesession>1</gamesession></root>"))
        XCTAssertEqual(noPort.rtspPort, MoonlightProtocol.defaultRtspPort, "the protocol's default when the URL names none")
        let refused = try XCTUnwrap(MoonlightXml.launchReply("<root status_code=\"400\"><gamesession>0</gamesession></root>"))
        XCTAssertFalse(refused.launched)
    }

    func testExternalEntitiesNeverResolve() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE root [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>"
            + "<root status_code=\"200\"><hostname>&xxe;</hostname></root>"
        let info = MoonlightXml.serverInfo(xml)
        XCTAssertFalse(info?.hostname.contains("root:") ?? false)
        XCTAssertFalse(info?.hostname.contains("/bin") ?? false)
    }
}
