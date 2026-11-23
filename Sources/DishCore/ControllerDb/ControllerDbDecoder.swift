// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The one reader of `controllers.json`, schema 1. A file whose schema is not
// 1 is refused whole; a record that does not decode (a missing id, a rule or
// a state this schema does not name) is left out and the rest stand, as the
// contract's "a row that does not decode is not applied" asks. Unknown
// fields, the reserved ones of section 11 among them, are ignored.

import Foundation

/// Why a file of the database was not taken.
public enum ControllerDbError: Error, Equatable, Sendable {
    /// Not JSON, or not the shape a schema 1 file has.
    case badJson
    /// `schema` is missing or is not 1.
    case unsupportedSchema
}

public enum ControllerDbSchema {
    public static let version = 1
    /// The Mac's key under `platforms`.
    public static let platform = "mac"
}

public func decodeControllerDatabase(_ data: Data) -> Result<ControllerDatabase, ControllerDbError> {
    guard let file = try? JSONDecoder().decode(DatabaseFile.self, from: data) else { return .failure(.badJson) }
    guard file.schema == ControllerDbSchema.version else { return .failure(.unsupportedSchema) }
    guard let dbVersion = file.dbVersion, let rows = file.records else { return .failure(.badJson) }
    let records = rows.compactMap(\.record).compactMap(controllerRecord)
    return .success(ControllerDatabase(dbVersion: dbVersion, records: records))
}

// MARK: - The file's shape

private struct DatabaseFile: Decodable {
    let schema: Int?
    let dbVersion: Int?
    let records: [LossyRecord]?
}

/// A record that fails to decode is nil, so it alone is dropped.
private struct LossyRecord: Decodable {
    let record: RecordFile?

    init(from decoder: Decoder) throws {
        record = try? RecordFile(from: decoder)
    }
}

private struct RecordFile: Decodable {
    struct Requires: Decodable {
        let families: [String]?
        let ops: [String]?
    }

    struct Identity: Decodable {
        let usb: [String]?
        let bluetooth: [String]?
    }

    struct Rule: Decodable {
        let rule: String
    }

    struct DirectHolder: Decodable {
        let direct: Rule?
    }

    struct ProtocolRef: Decodable {
        let ref: String
    }

    struct InputCaps: Decodable {
        let motion: Bool?
        let touchpad: Bool?
        let trackpads: Int?
        let battery: Bool?
        let extendedButtons: Bool?
    }

    struct Input: Decodable {
        let `protocol`: ProtocolRef
        let mapping: String?
        let direct: Rule
        let capabilities: InputCaps?
    }

    struct Init: Decodable {
        let kind: String
    }

    struct OutputCaps: Decodable {
        let rumble: Bool?
        let triggerRumble: Bool?
        let lightbar: Bool?
        let playerLeds: Bool?
        let micLed: Bool?
        let triggerEffects: Bool?
    }

    struct Output: Decodable {
        let route: String?
        let `init`: Init?
        let capabilities: OutputCaps?
    }

    struct Endpoints: Decodable {
        let `in`: Bool?
        let out: Bool?
    }

    struct Expect: Decodable {
        let endpoints: Endpoints?
    }

    struct Verification: Decodable {
        let state: String
    }

    struct Issue: Decodable {
        let id: String
        let device: String?
        let os: [String: OsVersion]?
        let transport: String?
        let lane: String?
        let status: String?
    }

    /// A platform's version, a number or a string such as "15" or "26.1":
    /// its major version, or nil for one that does not read as a number.
    struct OsVersion: Decodable {
        let major: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                major = number
                return
            }
            let text = try container.decode(String.self)
            major = text.split(separator: ".").first.flatMap { Int($0) }
        }
    }

    struct Support: Decodable {
        let verification: Verification
        let issues: [Issue]?
    }

    let schema: Int?
    let id: String
    let requires: Requires?
    let identity: Identity?
    let input: Input
    let output: Output?
    let expect: Expect?
    let platforms: [String: DirectHolder]?
    let support: Support
}

// MARK: - Into a record

private func controllerRecord(_ file: RecordFile) -> ControllerRecord? {
    let schemaFits = file.schema.map { $0 == ControllerDbSchema.version } ?? true
    guard schemaFits, !file.id.isEmpty else { return nil }
    let ruleWord = file.platforms?[ControllerDbSchema.platform]?.direct?.rule ?? file.input.direct.rule
    guard let rule = ControllerDirectRule(rawValue: ruleWord),
          let verification = ControllerVerification(rawValue: file.support.verification.state),
          let mapping = recordMapping(file.input.mapping), let route = recordRoute(file.output?.route) else { return nil }
    return ControllerRecord(
        id: file.id,
        requiredFamilies: file.requires?.families ?? [],
        requiredOps: file.requires?.ops ?? [],
        usb: (file.identity?.usb ?? []).map { $0.lowercased() },
        bluetooth: (file.identity?.bluetooth ?? []).map { $0.lowercased() },
        familyId: file.input.protocol.ref,
        mapping: mapping.value,
        directRule: rule,
        inputCapabilities: inputCapabilities(file.input.capabilities),
        outputRoute: route.value,
        initKind: file.output?.`init`?.kind ?? "none",
        outputCapabilities: outputCapabilities(file.output?.capabilities),
        expect: ControllerExpect(endpointIn: file.expect?.endpoints?.in, endpointOut: file.expect?.endpoints?.out),
        verification: verification,
        issues: (file.support.issues ?? []).map(controllerIssue)
    )
}

/// An optional field that names something this schema does not know is a
/// record that does not decode; an absent one is nil.
private struct Present<Value> {
    let value: Value?
}

private func recordMapping(_ word: String?) -> Present<ControllerMapping>? {
    guard let word else { return Present(value: nil) }
    return ControllerMapping(rawValue: word).map { Present(value: $0) }
}

private func recordRoute(_ word: String?) -> Present<ControllerOutputRoute>? {
    guard let word else { return Present(value: nil) }
    return ControllerOutputRoute(rawValue: word).map { Present(value: $0) }
}

private func inputCapabilities(_ caps: RecordFile.InputCaps?) -> ControllerInputCapabilities {
    ControllerInputCapabilities(
        motion: caps?.motion ?? false,
        touchpad: caps?.touchpad ?? false,
        trackpads: caps?.trackpads ?? 0,
        battery: caps?.battery ?? false,
        extendedButtons: caps?.extendedButtons ?? false
    )
}

private func outputCapabilities(_ caps: RecordFile.OutputCaps?) -> ControllerOutputCapabilities {
    ControllerOutputCapabilities(
        rumble: caps?.rumble ?? false,
        triggerRumble: caps?.triggerRumble ?? false,
        lightbar: caps?.lightbar ?? false,
        playerLeds: caps?.playerLeds ?? false,
        micLed: caps?.micLed ?? false,
        triggerEffects: caps?.triggerEffects ?? false
    )
}

/// A transport this schema does not name reads as none, so the issue is
/// shown on every transport rather than on none.
private func controllerIssue(_ issue: RecordFile.Issue) -> ControllerIssue {
    ControllerIssue(
        id: issue.id,
        device: issue.device,
        os: (issue.os ?? [:]).mapValues { $0.major ?? unreadableOsVersion },
        transport: issue.transport.flatMap(ControllerTransport.init(rawValue:)),
        lane: issue.lane,
        status: issue.status
    )
}

/// What a version that does not read as a number becomes: no OS has it, so
/// the issue never matches on that platform rather than on every version.
private let unreadableOsVersion = -1
