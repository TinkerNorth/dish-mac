// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The updater's one version grammar and ordering: strict MAJOR.MINOR.PATCH
// parsed to an integer triple and compared as a tuple. No prefix, no
// prerelease tag, no build metadata: the release permalink never points at
// those, and a looser grammar is how "0.10.0-rc1" ends up before "0.9.0".

import Foundation

public struct UpdateVersion: Equatable, Comparable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Strict `digits.digits.digits`; nil for anything else, including an
    /// empty part, a sign, whitespace, or a part that overflows `Int`.
    public static func parse(_ text: String) -> UpdateVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(digits)
        guard numbers.count == 3 else { return nil }
        return UpdateVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// A non-empty run of ASCII digits, or nil.
    private static func digits(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(part)
    }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public func isValidVersion(_ text: String) -> Bool {
    UpdateVersion.parse(text) != nil
}

/// -1, 0 or 1 when both sides parse; nil when either is malformed, so a call
/// site decides what an unparsable version means for it.
public func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
    guard let left = UpdateVersion.parse(lhs), let right = UpdateVersion.parse(rhs) else { return nil }
    if left < right { return -1 }
    if right < left { return 1 }
    return 0
}

/// True iff both parse and `candidate` is strictly newer than `baseline`:
/// malformed input can never rank above a real version.
public func isStrictlyNewer(_ candidate: String, than baseline: String) -> Bool {
    compareVersions(candidate, baseline) == 1
}
