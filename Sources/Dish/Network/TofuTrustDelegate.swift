// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// TOFU cert-pinning TLS delegate (PLAN D3 / gap G7). The satellite presents a
// SELF-SIGNED certificate, so platform trust evaluation can never succeed and
// is not attempted. Trust is Trust-On-First-Use instead: the composition root
// installs a `PinVerifier` that (via DishCore's verdict ladder and the
// ConnectionStore pin registry) pins the SHA-256 fingerprint of the DER cert
// first seen for a host and refuses any later cert whose fingerprint differs
// (anti-MITM). This replaces the deleted protocol-0 `InsecureTrustDelegate`,
// which accepted anything (`curl --insecure`). Mirrors the `encrypted`-signal
// seam in dish-linux `HTTPClient.cpp` / `PairingClient.cpp`.

import Foundation

/// The TOFU pin seam: given the request host (IP string) and the peer leaf
/// certificate's DER bytes, return true to trust (the request proceeds) or
/// false to reject (the handshake is cancelled before any request bytes
/// flow). Runs on URLSession's delegate queue — implementations must be
/// thread-safe.
typealias PinVerifier = @Sendable (_ host: String, _ certDER: Data) -> Bool

/// `URLSessionDelegate` enforcing TOFU pinning on every server-trust
/// challenge. Installed on the `HTTPClient` / `PairingClient` sessions by the
/// composition root (`WifiConnectionManager.makePinVerifier`).
final class TofuPinningDelegate: NSObject, URLSessionDelegate {

    private let verifier: PinVerifier

    init(verifier: @escaping PinVerifier) {
        self.verifier = verifier
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust else
        {
            // Not a server-trust challenge — let the system handle it.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let der = Self.leafCertificateDER(trust) else {
            // No certificate to judge — never trust blindly.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if verifier(challenge.protectionSpace.host, der) {
            // Pinned or first contact: accept the presented (self-signed)
            // chain without platform evaluation.
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // Fingerprint mismatch: abort the handshake. The request fails
            // like a dropped connection (reachable = false) and the pin is
            // kept — exactly the dish-linux `reply->abort()` semantics.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// DER bytes of the presented leaf certificate (the one the satellite
    /// minted — self-signed chains are length 1, but take index 0 either way:
    /// the LEAF is what the fingerprint pin is defined over).
    static func leafCertificateDER(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
