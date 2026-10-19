// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The two halves of talking to a Moonlight host: plain HTTP for /serverinfo
// and pairing phases 1 to 4, mutual TLS for everything a paired client is
// answered on. The host authorises paired clients by the client certificate
// alone; this side pins the host's certificate on first use, as it pins a
// satellite's, and after a pairing pins the certificate the five phases
// proved, which outranks a pin written for a host since rebuilt.

import DishCore
import Foundation
import Security

/// Where the host pins live: the connection store's registry, keyed by the
/// Moonlight host id.
protocol MoonlightPinRegistry: AnyObject {
    func certPin(host: String) -> String?
    func setCertPin(host: String, fingerprintHex: String)
    func forgetCertPin(host: String)
}

extension ConnectionStore: MoonlightPinRegistry {}

final class MoonlightGateway {
    /// Minted in the keychain off the main thread at launch and adopted
    /// here; a secure call before that presents no client certificate.
    private let identity: LockedBox<MoonlightIdentityStore?>
    private let pins: MoonlightPinRegistry
    private let transport: MoonlightHttpTransport

    init(identity: MoonlightIdentityStore?, pins: MoonlightPinRegistry, transport: MoonlightHttpTransport = MoonlightHttpTransport()) {
        self.identity = LockedBox(identity)
        self.pins = pins
        self.transport = transport
    }

    func adoptIdentity(_ store: MoonlightIdentityStore) {
        identity.set(store)
    }

    /// Plain HTTP: /serverinfo on the plaintext port and pairing phases 1 to
    /// 4, which the protocol fixes there. The PIN never crosses the wire.
    func getPlain(
        _ request: MoonlightHttpRequest,
        timeout: TimeInterval = MoonlightHttpTransport.plainTimeout
    ) async -> MoonlightHttpReply {
        await transport.get(request, tls: nil, timeout: timeout)
    }

    /// Mutual TLS under the pin on first use: a host never seen is pinned, a
    /// pinned one must present the same leaf, and another leaf is refused
    /// inside the handshake.
    func getSecure(_ request: MoonlightHttpRequest, hostId: String) async -> MoonlightHttpReply {
        let pins = pins
        let tls = MoonlightTls(identity: identity.get()?.secIdentity()) { leaf in
            let presented = sha256FingerprintHex(leaf)
            switch tofuVerdict(pinned: pins.certPin(host: hostId), presented: presented) {
            case .trustFirstUse:
                pins.setCertPin(host: hostId, fingerprintHex: presented)
                return true
            case .match:
                return true
            case .mismatch:
                return false
            }
        }
        return await transport.get(request, tls: tls, timeout: MoonlightHttpTransport.tlsTimeout)
    }

    /// Mutual TLS trusting one certificate and no other, whatever is pinned:
    /// the one phases 1 to 4 proved, for phase 5.
    func getSecureTrusting(_ request: MoonlightHttpRequest, certificateDER: Data) async -> MoonlightHttpReply {
        let expected = sha256FingerprintHex(certificateDER)
        let tls = MoonlightTls(identity: identity.get()?.secIdentity()) { leaf in sha256FingerprintHex(leaf) == expected }
        return await transport.get(request, tls: tls, timeout: MoonlightHttpTransport.tlsTimeout)
    }

    func pinnedFingerprint(hostId: String) -> String? {
        pins.certPin(host: hostId)
    }

    /// A pairing proved this certificate: it replaces whatever was pinned.
    func pinProven(hostId: String, certificateDER: Data) {
        pins.setCertPin(host: hostId, fingerprintHex: sha256FingerprintHex(certificateDER))
    }

    /// Re-arms first use for the host; a forget and a fold both settle which machine it is.
    func forgetPin(hostId: String) {
        pins.forgetCertPin(host: hostId)
    }

    /// One host's two ids filed under one: the pin the trusted record held
    /// stays, two pins that disagree are two machines and neither is kept.
    /// Returns whether they agreed.
    func foldPins(from fromHostId: String, to toHostId: String, trusted trustedHostId: String) -> Bool {
        let moving = pins.certPin(host: fromHostId)
        let staying = pins.certPin(host: toHostId)
        let agree = moving == nil || staying == nil || moving == staying
        let kept = agree ? pins.certPin(host: trustedHostId) : nil
        pins.forgetCertPin(host: fromHostId)
        if kept != staying {
            pins.forgetCertPin(host: toHostId)
            if let kept { pins.setCertPin(host: toHostId, fingerprintHex: kept) }
        }
        return agree
    }
}
