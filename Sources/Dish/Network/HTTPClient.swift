// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Async gateway to the satellite's protocol-1 client REST API (HTTPS
/// `:9443`). Mirrors dish-linux `Network/HTTPClient` / dish-android's
/// `SatelliteHttpClient`.
///
/// Every authenticated route attaches `X-Device-Id` + `X-Hmac-Proof` — the
/// proof = `hex(HMAC-SHA256(pairingKey, "satellite-proof:" + deviceId))`,
/// computed by the caller via `DishCore.SessionCrypto` and passed in — so a
/// client whose key diverged from the server's fails at REST time with a
/// terminal 401 instead of producing a silently-undecryptable UDP session
/// (contract §hmacProof, gap G6).
///
/// TLS: the satellite's cert is self-signed, so there is no CA chain to
/// validate. Trust is enforced by TOFU cert-pinning via the
/// `TofuPinningDelegate` installed at init — first contact pins, a mismatch
/// aborts the exchange, which surfaces here as unreachable (status 0).
final class HTTPClient {

    private let session: URLSession

    init(pinVerifier: @escaping PinVerifier) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        session = URLSession(
            configuration: cfg,
            delegate: TofuPinningDelegate(verifier: pinVerifier),
            delegateQueue: nil
        )
    }

    deinit {
        // URLSession retains its delegate until invalidated.
        session.finishTasksAndInvalidate()
    }

    // MARK: - Routes (contract §Session / §Controller / §Pairing Delete)

    private struct PutSessionBody: Encodable {
        let deviceId: String
        let deviceName: String
        let protocolVersion: Int
        let hmacProof: String
        let controllers: [ControllerDescriptor]
        let hostFeatures: HostFeaturesBody

        struct HostFeaturesBody: Encodable {
            let mouseControl: Bool
        }
    }

    /// `PUT /api/connections` — declarative session upsert. `controllers` is
    /// the WHOLE desired set (empty = a valid zero-controller session);
    /// `mouseControl` is the requested host feature (v1 sends false — the
    /// touchpad-mouse UI is deferred — but the grant still parses).
    func putSession(
        ip: String,
        port: Int,
        deviceId: String,
        deviceName: String,
        hmacProof: String,
        controllers: [ControllerDescriptor],
        mouseControl: Bool = false
    ) async -> SessionResponse {
        let body = try? JSONEncoder().encode(PutSessionBody(
            deviceId: deviceId,
            deviceName: deviceName,
            protocolVersion: ProtocolConstants.protocolVersion,
            hmacProof: hmacProof,
            controllers: controllers,
            hostFeatures: .init(mouseControl: mouseControl)
        ))
        let raw = await perform(
            path: "/api/connections",
            ip: ip,
            port: port,
            method: "PUT",
            body: body,
            deviceId: deviceId,
            hmacProof: hmacProof
        )
        return stamp(decode(SessionResponse.self, from: raw), raw)
    }

    /// `GET /api/connections/{id}` — the reconcile endpoint (applied state +
    /// epoch; contract §Enriched heartbeat ack).
    func getSession(
        ip: String,
        port: Int,
        connectionId: String,
        deviceId: String,
        hmacProof: String
    ) async -> SessionViewDto {
        let raw = await perform(
            path: "/api/connections/\(connectionId)",
            ip: ip,
            port: port,
            method: "GET",
            body: nil,
            deviceId: deviceId,
            hmacProof: hmacProof
        )
        return stamp(decode(SessionViewDto.self, from: raw), raw)
    }

    /// `DELETE /api/connections/{id}` — graceful close (no notify: the
    /// closer already knows).
    @discardableResult
    func deleteSession(
        ip: String,
        port: Int,
        connectionId: String,
        deviceId: String,
        hmacProof: String
    ) async -> RestReply {
        let raw = await perform(
            path: "/api/connections/\(connectionId)",
            ip: ip,
            port: port,
            method: "DELETE",
            body: nil,
            deviceId: deviceId,
            hmacProof: hmacProof
        )
        return ack(raw)
    }

    /// `PUT /api/connections/{id}/controllers/{idx}` — standalone
    /// single-descriptor upsert; converges without rotating the token (the
    /// path idx wins server-side).
    func putController(
        ip: String,
        port: Int,
        connectionId: String,
        deviceId: String,
        hmacProof: String,
        descriptor: ControllerDescriptor
    ) async -> ControllerPutResponse {
        let raw = await perform(
            path: "/api/connections/\(connectionId)/controllers/\(descriptor.ctrlIdx)",
            ip: ip,
            port: port,
            method: "PUT",
            body: try? JSONEncoder().encode(descriptor),
            deviceId: deviceId,
            hmacProof: hmacProof
        )
        return stamp(decode(ControllerPutResponse.self, from: raw), raw)
    }

    /// `DELETE /api/connections/{id}/controllers/{idx}` — removes the SLOT
    /// only; the session lives on.
    func deleteController(
        ip: String,
        port: Int,
        connectionId: String,
        ctrlIdx: Int,
        deviceId: String,
        hmacProof: String
    ) async -> ControllerPutResponse {
        let raw = await perform(
            path: "/api/connections/\(connectionId)/controllers/\(ctrlIdx)",
            ip: ip,
            port: port,
            method: "DELETE",
            body: nil,
            deviceId: deviceId,
            hmacProof: hmacProof
        )
        return stamp(decode(ControllerPutResponse.self, from: raw), raw)
    }

    /// `DELETE /api/pair` — client self-unpair (contract §Pairing Delete;
    /// gap G16). The satellite closes any live session (notify `unpaired`)
    /// and drops this deviceId from its operator list.
    @discardableResult
    func unpair(ip: String, port: Int, deviceId: String, hmacProof: String) async -> RestReply {
        let raw = await perform(
            path: "/api/pair",
            ip: ip,
            port: port,
            method: "DELETE",
            body: nil,
            deviceId: deviceId,
            hmacProof: hmacProof
        )
        return ack(raw)
    }

    // MARK: - Plumbing

    /// One exchange's raw result, before route-specific DTO parsing.
    /// `status == 0` means the transport never produced a response.
    private struct RawReply {
        var status = 0
        var body = Data()
        /// A transport-level failure with no HTTP status is unreachable; a
        /// body (including a 4xx/5xx error body) means the server answered.
        var reachable: Bool {
            status != 0 || !body.isEmpty
        }
    }

    private func perform(
        path: String,
        ip: String,
        port: Int,
        method: String,
        body: Data?,
        deviceId: String,
        hmacProof: String
    ) async -> RawReply {
        guard let url = URL(string: "https://\(ip):\(port)\(path)") else { return RawReply() }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Every authenticated route carries the device id + a proof of the
        // pairing key (contract §hmacProof). Empty values are omitted — the
        // pairing bootstrap routes are the only unauthenticated ones.
        if !deviceId.isEmpty { req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id") }
        if !hmacProof.isEmpty { req.setValue(hmacProof, forHTTPHeaderField: "X-Hmac-Proof") }
        req.httpBody = body
        do {
            let (data, response) = try await session.data(for: req)
            return RawReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            // Includes TOFU mismatch aborts — indistinguishable from a
            // dropped connection by design.
            return RawReply()
        }
    }

    /// Lenient decode: an unreachable reply or an unparseable body yields the
    /// DTO's defaults (mirrors dish-linux `parseObject` returning `{}`).
    private func decode<T: Decodable>(_ type: T.Type, from raw: RawReply) -> T? {
        guard raw.reachable, !raw.body.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: raw.body)
    }

    private func stamp(_ decoded: SessionResponse?, _ raw: RawReply) -> SessionResponse {
        var out = decoded ?? SessionResponse()
        out.httpStatus = raw.status
        out.reachable = raw.reachable
        return out
    }

    private func stamp(_ decoded: SessionViewDto?, _ raw: RawReply) -> SessionViewDto {
        var out = decoded ?? SessionViewDto()
        out.httpStatus = raw.status
        out.reachable = raw.reachable
        return out
    }

    private func stamp(_ decoded: ControllerPutResponse?, _ raw: RawReply) -> ControllerPutResponse {
        var out = decoded ?? ControllerPutResponse()
        out.httpStatus = raw.status
        out.reachable = raw.reachable
        return out
    }

    /// Generic ack for routes the caller doesn't decode (DELETE pair /
    /// session): DishCore's `RestReply` feeds `classifyRest` and the
    /// terminal-401 check.
    private func ack(_ raw: RawReply) -> RestReply {
        let code = decode(SessionResponse.self, from: raw)?.code ?? ""
        return RestReply(status: raw.status, bodyParsed: raw.reachable, code: code)
    }
}
