// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Any JSON document, kept as it came: what a host says of itself rides the
/// diagnostics bundle whole, without the client knowing every field. A whole
/// number stays an integer, so a millisecond stamp survives the trip.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value under `key` of an object; nil for anything else.
    public subscript(key: String) -> JSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? {
        guard case let .string(text) = self else { return nil }
        return text
    }

    /// The document with every string, keys included, passed through
    /// `transform`; two keys it makes one keep the later value.
    public func mappingStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .null, .bool, .integer, .number: self
        case let .string(text): .string(transform(text))
        case let .array(items): .array(items.map { $0.mappingStrings(transform) })
        case let .object(fields): .object(mappedFields(fields, transform))
        }
    }

    private func mappedFields(_ fields: [String: JSONValue], _ transform: (String) -> String) -> [String: JSONValue] {
        let pairs = fields.map { key, value in (transform(key), value.mappingStrings(transform)) }
        return Dictionary(pairs) { _, later in later }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let whole = try? container.decode(Int64.self) {
            self = .integer(whole)
        } else if let real = try? container.decode(Double.self) {
            self = .number(real)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(flag): try container.encode(flag)
        case let .integer(whole): try container.encode(whole)
        case let .number(real): try container.encode(real)
        case let .string(text): try container.encode(text)
        case let .array(items): try container.encode(items)
        case let .object(fields): try container.encode(fields)
        }
    }
}

/// The document `data` holds; nil when it is not JSON.
public func parseJSONValue(_ data: Data) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: data)
}
