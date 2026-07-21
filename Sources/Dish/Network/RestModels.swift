// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Protocol-1 REST control-plane DTOs (contract §Session / §Controller /
// §Pairing). Field names mirror dish-linux Models.h / dish-windows /
// dish-android verbatim so the JSON on the wire stays byte-for-byte
// compatible. Parsing is lenient (missing fields fall back to defaults) so
// one decoder serves both success and error bodies — the error body shape
// `{"error","code"}` rides the same DTOs.

import DishCore
import Foundation

// MARK: - Session / controller responses

/// One controller's apply outcome inside a session/controller PUT response.
/// `result` is the protocol string (never localized); `resultCode` is its
/// `ApplyResult` mapping. `motion*` mirror the response's motion sub-object.
struct ControllerApplyDto: Decodable, Equatable {
    var ctrlIdx = 0
    var result = ""
    var resultCode = ApplyResult.unknown
    var appliedType = Int(ProtocolConstants.controllerTypeXbox)
    var motionSinkSupportedForType = false
    var motionBackendOk = false

    var ok: Bool {
        resultCode == .ok
    }

    /// replugFailed leaves the PREVIOUS pad live (`appliedType` reports it):
    /// streams keep flowing rather than killing a working pad.
    var slotIsLive: Bool {
        resultCode.slotIsLive
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case ctrlIdx, result, appliedType, motion }
    private struct MotionDto: Decodable {
        var sinkSupportedForType: Bool?
        var backendOk: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ctrlIdx = try container.decodeIfPresent(Int.self, forKey: .ctrlIdx) ?? 0
        self.result = try container.decodeIfPresent(String.self, forKey: .result) ?? ""
        self.resultCode = ApplyResult(wireName: result)
        self.appliedType = try container.decodeIfPresent(Int.self, forKey: .appliedType)
            ?? Int(ProtocolConstants.controllerTypeXbox)
        let motion = try container.decodeIfPresent(MotionDto.self, forKey: .motion)
        self.motionSinkSupportedForType = motion?.sinkSupportedForType ?? false
        self.motionBackendOk = motion?.backendOk ?? false
    }
}

/// Host-feature grant (server policy, returned in the PUT/GET response).
struct HostFeatureGrant: Decodable, Equatable {
    var granted = false
    /// `notSupported` | `backendUnavailable` | `denied`, when `!granted`
    /// (protocol constants, never localized).
    var reason: String?

    init(granted: Bool = false, reason: String? = nil) {
        self.granted = granted
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case granted, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.granted = try container.decodeIfPresent(Bool.self, forKey: .granted) ?? false
        let raw = try container.decodeIfPresent(String.self, forKey: .reason)
        self.reason = (raw?.isEmpty ?? true) ? nil : raw
    }
}

/// Shared lenient decode of the `hostFeatures` response object.
private struct HostFeaturesDto: Decodable {
    var mouseControl: HostFeatureGrant?
}

/// `PUT /api/connections` response. Also doubles as the error body
/// (`error`/`code`). `sessionSalt` (16-hex → 8 bytes) + `token` feed
/// `SessionCrypto.deriveSessionKey`; a missing `sessionSalt` means the key
/// can't be derived (a pre-protocol-1 server).
struct SessionResponse: Decodable {
    var connectionId: String?
    /// 8-hex (4 bytes BE).
    var token: String?
    /// 16-hex (8 bytes).
    var sessionSalt: String?
    var epoch = 0
    var maxControllers = ProtocolConstants.maxControllersPerConnection
    var protocolVersion = ProtocolConstants.protocolVersion
    var controllers: [ControllerApplyDto] = []
    var mouseControl = HostFeatureGrant()
    var error: String?
    /// Machine-readable 401 cause: `NOT_PAIRED` | `BAD_PROOF`. Either is terminal.
    var code: String?
    /// HTTP status of the exchange (0 = transport never produced a response).
    /// Client-side, stamped by `HTTPClient`.
    var httpStatus = 0
    /// True iff any body was received (even an error body). Client-side.
    var reachable = false

    var unauthorized: Bool {
        isTerminalAuthCode(code)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case connectionId, token, sessionSalt, epoch, maxControllers, protocolVersion
        case controllers, hostFeatures, error, code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connectionId = try nonEmpty(container.decodeIfPresent(String.self, forKey: .connectionId))
        self.token = try nonEmpty(container.decodeIfPresent(String.self, forKey: .token))
        self.sessionSalt = try nonEmpty(container.decodeIfPresent(String.self, forKey: .sessionSalt))
        self.epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        self.maxControllers = try container.decodeIfPresent(Int.self, forKey: .maxControllers)
            ?? ProtocolConstants.maxControllersPerConnection
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? ProtocolConstants.protocolVersion
        self.controllers = try container.decodeIfPresent([ControllerApplyDto].self, forKey: .controllers) ?? []
        let hostFeatures = try container.decodeIfPresent(HostFeaturesDto.self, forKey: .hostFeatures)
        self.mouseControl = hostFeatures?.mouseControl ?? HostFeatureGrant()
        self.error = try nonEmpty(container.decodeIfPresent(String.self, forKey: .error))
        self.code = try nonEmpty(container.decodeIfPresent(String.self, forKey: .code))
    }
}

/// `PUT/DELETE /api/connections/{id}/controllers/{idx}` response: one
/// controller's apply result + the session epoch (no token rotation on the
/// per-controller routes).
struct ControllerPutResponse: Decodable {
    var epoch = 0
    var controller: ControllerApplyDto?
    var error: String?
    var code: String?
    var httpStatus = 0
    var reachable = false

    var unauthorized: Bool {
        isTerminalAuthCode(code)
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case epoch, controller, error, code }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        self.controller = try container.decodeIfPresent(ControllerApplyDto.self, forKey: .controller)
        self.error = try nonEmpty(container.decodeIfPresent(String.self, forKey: .error))
        self.code = try nonEmpty(container.decodeIfPresent(String.self, forKey: .code))
    }
}

/// One applied controller from `GET /api/connections/{id}` (the reconcile view).
struct SessionViewControllerDto: Decodable, Equatable {
    var ctrlIdx = 0
    var active = false
    var appliedType = Int(ProtocolConstants.controllerTypeXbox)
    var touchpadMode = ""

    init() {}

    private enum CodingKeys: String, CodingKey { case ctrlIdx, active, appliedType, touchpadMode }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ctrlIdx = try container.decodeIfPresent(Int.self, forKey: .ctrlIdx) ?? 0
        self.active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        self.appliedType = try container.decodeIfPresent(Int.self, forKey: .appliedType)
            ?? Int(ProtocolConstants.controllerTypeXbox)
        self.touchpadMode = try container.decodeIfPresent(String.self, forKey: .touchpadMode) ?? ""
    }
}

/// `GET /api/connections/{id}`: the reconcile endpoint's applied state + epoch.
struct SessionViewDto: Decodable {
    var connectionId: String?
    var epoch = 0
    var controllers: [SessionViewControllerDto] = []
    var mouseControl = HostFeatureGrant()
    var error: String?
    var code: String?
    var httpStatus = 0
    var reachable = false

    var unauthorized: Bool {
        isTerminalAuthCode(code)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case connectionId, epoch, controllers, hostFeatures, error, code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connectionId = try nonEmpty(container.decodeIfPresent(String.self, forKey: .connectionId))
        self.epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        self.controllers = try container.decodeIfPresent(
            [SessionViewControllerDto].self, forKey: .controllers
        ) ?? []
        let hostFeatures = try container.decodeIfPresent(HostFeaturesDto.self, forKey: .hostFeatures)
        self.mouseControl = hostFeatures?.mouseControl ?? HostFeatureGrant()
        self.error = try nonEmpty(container.decodeIfPresent(String.self, forKey: .error))
        self.code = try nonEmpty(container.decodeIfPresent(String.self, forKey: .code))
    }
}

/// `GET /api/pair/status` response (path-B poll, contract §Pairing Read).
/// `status` ∈ `approved` | `pending` | `denied` | `none` (protocol constants).
struct PairStatusResponse: Decodable {
    var ok = false
    var status = ""
    var sharedKey: String?
    var httpStatus = 0
    var reachable = false

    init() {}

    private enum CodingKeys: String, CodingKey { case ok, status, sharedKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        self.sharedKey = try nonEmpty(container.decodeIfPresent(String.self, forKey: .sharedKey))
    }
}

// MARK: - Request bodies

/// Declarative per-controller desired state sent in the session/controller
/// PUT body. Always sent WHOLE (a toggle = re-send with one field changed);
/// the server converges (contract §Session Descriptor rules). The `caps` word
/// uses the `ProtocolConstants.cap*` bits and encodes as the contract's
/// boolean caps object.
struct ControllerDescriptor: Encodable, Hashable {
    var ctrlIdx = 0
    var type = ProtocolConstants.controllerTypeXbox
    /// `ProtocolConstants.cap*` bit word (analogTriggers/rumble/motion/lightbar).
    var caps: UInt16 = 0
    var touchpadMode = TouchpadMode.off

    private enum CodingKeys: String, CodingKey { case ctrlIdx, type, caps, touchpadMode }
    private enum CapsKeys: String, CodingKey { case rumble, motion, analogTriggers, lightbar }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ctrlIdx, forKey: .ctrlIdx)
        try container.encode(Int(type), forKey: .type)
        var capsContainer = container.nestedContainer(keyedBy: CapsKeys.self, forKey: .caps)
        try capsContainer.encode(caps & ProtocolConstants.capRumble != 0, forKey: .rumble)
        try capsContainer.encode(caps & ProtocolConstants.capMotion != 0, forKey: .motion)
        try capsContainer.encode(caps & ProtocolConstants.capAnalogTriggers != 0, forKey: .analogTriggers)
        try capsContainer.encode(caps & ProtocolConstants.capLightbar != 0, forKey: .lightbar)
        try container.encode(touchpadMode.wireName, forKey: .touchpadMode)
    }
}

// MARK: - Shared helpers

/// `nil`-out empty strings so `optional == nil` uniformly means "absent",
/// matching dish-linux's `setIfNonEmpty` parse rule.
private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// True when a 401 body's machine code is one of the two TERMINAL causes —
/// the client drops its key and stops retrying (contract §hmacProof).
func isTerminalAuthCode(_ code: String?) -> Bool {
    code == ProtocolConstants.authCodeNotPaired || code == ProtocolConstants.authCodeBadProof
}

/// The client-side stamp every authed-route DTO carries (`HTTPClient` fills
/// `httpStatus`/`reachable`), so the exchange can be classified through
/// DishCore's error-model reducer instead of open-coded status checks
/// (PLAN D2: the shell delegates decisions to DishCore).
protocol RestStamped {
    var httpStatus: Int { get }
    var reachable: Bool { get }
    var code: String? { get }
}

extension RestStamped {
    /// `DishCore.classifyRest` over the stamped exchange. `bodyParsed` maps
    /// to `reachable` (this gateway's only bodyless replies are the status-0
    /// transport-failure sentinel), which makes the mapping exact:
    /// `verdict == .unauthorized` ⇔ `httpStatus == 401` and
    /// `verdict == .versionMismatch` ⇔ `httpStatus == 409` — any non-zero
    /// status implies `reachable`. Same construction the live-HTTP tests pin.
    var verdict: RestVerdict {
        classifyRest(RestReply(status: httpStatus, bodyParsed: reachable, code: code ?? ""))
    }
}

extension SessionResponse: RestStamped {}
extension ControllerPutResponse: RestStamped {}
extension SessionViewDto: RestStamped {}
