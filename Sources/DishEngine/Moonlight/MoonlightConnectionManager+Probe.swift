// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Re-verifying what the dish knows about a host without touching a session.
/// The plaintext probe answers reachability and who is behind the address;
/// the mutual-TLS probe is the only proof the pairing still stands, since
/// Sunshine computes PairStatus only on that route and hands every plaintext
/// caller a 0.
extension MoonlightConnectionManager {
    func probe(_ host: MoonlightHost) async -> MoonlightProbe {
        let epoch = epochOf(host.id)
        let plain = await plainServerInfo(host.endpoint)
        if forgottenSince(host.id, epoch) { return .forgotten }
        if let plain {
            noteFacts(host.id, plain)
            keepFirstUniqueId(host.id, plain)
        }
        // Holding a pairing is the paired flag, never a non-empty uniqueid: real
        // hosts publish no uniqueid over mDNS at all.
        let record = store.host(id: host.id).flatMap { $0.paired ? $0 : nil }
        guard let plain else { return MoonlightProbe(trust: record == nil ? .unreachable : .remembered) }
        let storedId = record?.uniqueId ?? ""
        if !storedId.isEmpty, !plain.uniqueId.isEmpty, plain.uniqueId != storedId { return MoonlightProbe(trust: .replaced) }
        return await probeOverMutualTls(host, holdsAPairing: record != nil, epoch: epoch)
    }

    /// Plain HTTP answers any caller, paired or not, and names the machine behind the address.
    func plainServerInfo(_ endpoint: MoonlightEndpoint) async -> MoonlightServerInfo? {
        let reply = await gateway.getPlain(
            MoonlightUrls.serverInfo(endpoint, tls: false, uniqueId: uniqueId, nonce: nonce()),
            timeout: MoonlightHttpTransport.plainTimeout
        )
        guard reply.ok else { return nil }
        return MoonlightXml.serverInfo(reply.body)
    }

    private func probeOverMutualTls(_ host: MoonlightHost, holdsAPairing: Bool, epoch: Int) async -> MoonlightProbe {
        let secure = await gateway.getSecure(
            MoonlightUrls.serverInfo(host.endpoint, tls: true, uniqueId: uniqueId, nonce: nonce()),
            hostId: host.id
        )
        if forgottenSince(host.id, epoch) { return .forgotten }
        let untrusted: MoonlightTrustState = holdsAPairing ? .trustLost : .notPaired
        guard secure.ok, let info = MoonlightXml.serverInfo(secure.body) else { return MoonlightProbe(trust: untrusted) }
        noteFacts(host.id, info)
        guard info.paired else { return MoonlightProbe(trust: untrusted) }
        let apps = await fetchAppList(host)
        if forgottenSince(host.id, epoch) { return .forgotten }
        markVerified(host.id)
        return MoonlightProbe(
            trust: .paired,
            apps: apps ?? [],
            appsFetched: apps != nil,
            appsFailed: apps == nil,
            currentGame: info.currentGame
        )
    }

    /// The host's apps; nil for a refusal in the status line or the body, or
    /// a reply that does not parse: none of them says what the host can start.
    func fetchAppList(_ host: MoonlightHost) async -> [MoonlightApp]? {
        let reply = await gateway.getSecure(MoonlightUrls.appList(host.endpoint, uniqueId: uniqueId, nonce: nonce()), hostId: host.id)
        guard reply.ok, let status = MoonlightXml.status(reply.body), status.ok else { return nil }
        return MoonlightXml.appList(reply.body)
    }

    /// Whether the host answers a paired client over mutual TLS right now.
    func isPaired(_ host: MoonlightHost) async -> Bool {
        let reply = await gateway.getSecure(
            MoonlightUrls.serverInfo(host.endpoint, tls: true, uniqueId: uniqueId, nonce: nonce()),
            hostId: host.id
        )
        guard reply.ok else { return false }
        return MoonlightXml.serverInfo(reply.body)?.paired == true
    }
}
