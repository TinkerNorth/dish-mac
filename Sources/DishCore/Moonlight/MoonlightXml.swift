// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What a Moonlight host answers over HTTP: XML with a `<root>` whose
// attributes carry the host's own verdict. A host says no in the body, not in
// the status line: a second /launch is answered HTTP 200 with
// `status_code="400"` and "An app is already running on this host". Read the
// root first. External entities are never resolved; the input is the network.

import Foundation

/// The root element's verdict. No `status_code` at all reads as success,
/// which is how a plain host (Wolf's /applist) answers; one that is not a
/// number reads as failure, because a garbled answer is not a yes.
public struct MoonlightStatus: Equatable, Sendable {
    public static let defaultOk = 200
    public static let unreadable = -1

    public var code: Int
    public var message: String
    public var resume: Bool

    public init(code: Int, message: String, resume: Bool) {
        self.code = code
        self.message = message
        self.resume = resume
    }

    public var ok: Bool {
        (200 ... 299).contains(code)
    }

    /// The host already runs an app: /resume it when `resume`, else /cancel.
    public var appAlreadyRunning: Bool {
        !ok && message.lowercased().contains("already running")
    }
}

public struct MoonlightServerInfo: Equatable, Sendable {
    public var hostname: String
    public var uniqueId: String
    public var pairStatus: Int
    public var currentGame: Int
    public var state: String
    public var httpsPort: UInt16?
    public var externalPort: UInt16?
    public var mac: String?
    public var localIp: String?
    public var appVersion: String?
    public var gfeVersion: String?

    public var paired: Bool {
        pairStatus == 1
    }

    public var busy: Bool {
        currentGame != 0 || state.hasSuffix("SERVER_BUSY")
    }
}

public struct MoonlightPairReply: Equatable, Sendable {
    public var paired: Bool
    public var plainCert: String?
    public var challengeResponse: String?
    public var pairingSecret: String?
    public var statusMessage: String?
}

public struct MoonlightApp: Equatable, Sendable {
    public var id: String
    public var title: String
    public var hdrSupported: Bool
}

/// A /launch or /resume that the host accepted: the RTSP address it named.
public struct MoonlightLaunchReply: Equatable, Sendable {
    public var gameSession: Int
    public var sessionUrl: String?

    public var launched: Bool {
        gameSession != 0
    }

    /// The port in `rtsp://host:port`; the protocol's default when the URL names none.
    public var rtspPort: UInt16 {
        guard let url = sessionUrl, let port = URLComponents(string: url)?.port, (1 ... 65535).contains(port) else {
            return MoonlightProtocol.defaultRtspPort
        }
        return UInt16(port)
    }
}

public enum MoonlightXml {
    public static func status(_ xml: String) -> MoonlightStatus? {
        guard let root = XmlElement.root(of: xml) else { return nil }
        let code: Int = if let named = root.attributes["status_code"] {
            Int(named) ?? MoonlightStatus.unreadable
        } else {
            MoonlightStatus.defaultOk
        }
        return MoonlightStatus(code: code, message: root.attributes["status_message"] ?? "", resume: root.int("resume") == 1)
    }

    public static func serverInfo(_ xml: String) -> MoonlightServerInfo? {
        guard let root = XmlElement.root(of: xml) else { return nil }
        return MoonlightServerInfo(
            hostname: root.text("hostname") ?? "",
            uniqueId: root.text("uniqueid") ?? "",
            pairStatus: root.int("PairStatus") ?? 0,
            currentGame: root.int("currentgame") ?? 0,
            state: root.text("state") ?? "",
            httpsPort: root.port("HttpsPort"),
            externalPort: root.port("ExternalPort"),
            mac: root.text("mac"),
            localIp: root.text("LocalIP"),
            appVersion: root.text("appversion"),
            gfeVersion: root.text("GfeVersion")
        )
    }

    public static func pairReply(_ xml: String) -> MoonlightPairReply? {
        guard let root = XmlElement.root(of: xml) else { return nil }
        return MoonlightPairReply(
            paired: root.int("paired") == 1,
            plainCert: root.text("plaincert"),
            challengeResponse: root.text("challengeresponse"),
            pairingSecret: root.text("pairingsecret"),
            statusMessage: root.attributes["status_message"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Every `<App>` with an `<ID>`; the title may be empty.
    public static func appList(_ xml: String) -> [MoonlightApp] {
        guard let root = XmlElement.root(of: xml) else { return [] }
        return root.descendants(named: "App").compactMap { app in
            app.text("ID").map { MoonlightApp(id: $0, title: app.text("AppTitle") ?? "", hdrSupported: app.int("IsHdrSupported") == 1) }
        }
    }

    public static func launchReply(_ xml: String) -> MoonlightLaunchReply? {
        guard let root = XmlElement.root(of: xml) else { return nil }
        return MoonlightLaunchReply(gameSession: root.int("gamesession") ?? 0, sessionUrl: root.text("sessionUrl0"))
    }
}

/// A tree of elements with their attributes and text, built by Foundation's
/// parser with external entities off.
final class XmlElement {
    let name: String
    let attributes: [String: String]
    private(set) var characters = ""
    private(set) var children: [XmlElement] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func root(of xml: String) -> XmlElement? {
        let builder = XmlTreeBuilder()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    func append(child: XmlElement) {
        children.append(child)
    }

    func append(text: String) {
        characters += text
    }

    /// The first descendant with this name, depth first, as a host's DOM lookup finds it.
    func descendants(named name: String) -> [XmlElement] {
        children.flatMap { child in (child.name == name ? [child] : []) + child.descendants(named: name) }
    }

    /// The trimmed text of the first descendant with this name; nil when absent or empty.
    func text(_ name: String) -> String? {
        guard let value = descendants(named: name).first?.characters.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    func int(_ name: String) -> Int? {
        text(name).flatMap(Int.init)
    }

    func port(_ name: String) -> UInt16? {
        int(name).flatMap { (1 ... 65535).contains($0) ? UInt16($0) : nil }
    }
}

private final class XmlTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XmlElement?
    private var stack: [XmlElement] = []

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let element = XmlElement(name: name, attributes: attributes)
        if let parent = stack.last {
            parent.append(child: element)
        } else {
            root = element
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.append(text: string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        stack.last?.append(text: String(bytes: block, encoding: .utf8) ?? "")
    }
}
