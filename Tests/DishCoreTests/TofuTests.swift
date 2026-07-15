// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// TOFU pinning (PURE) — the verdict ladder + SHA-256 known-answer vectors,
// the SAME cases satellite / dish-windows / dish-linux / dish-android pin —
// any drift is a cross-end protocol break. The verdict rules:
//   * pinned == nil          -> trustFirstUse  (only never-pinned trusts)
//   * equalsIgnoreCase(hex)  -> match
//   * otherwise              -> mismatch       (an empty-string pin CAN mismatch)
// The fingerprint is lowercase 64-hex SHA-256 of the cert DER bytes.

import XCTest
import DishCore

final class TofuTests: XCTestCase {

    func testNoPriorPinTrustsFirstUse() {
        XCTAssertEqual(tofuVerdict(pinned: nil, presented: "aabb"), .trustFirstUse)
    }

    func testEqualFingerprintIsAMatch() {
        XCTAssertEqual(tofuVerdict(pinned: "aabb", presented: "aabb"), .match)
    }

    func testMatchIsCaseInsensitiveOnHex() {
        XCTAssertEqual(tofuVerdict(pinned: "AABBcc", presented: "aabbCC"), .match)
    }

    func testDifferentFingerprintIsAMismatch() {
        XCTAssertEqual(tofuVerdict(pinned: "aabb", presented: "ccdd"), .mismatch)
    }

    func testAnEmptyStoredStringCanStillMismatch() {
        // Only nil is "never pinned"; an empty-string pin is present and differs.
        XCTAssertEqual(tofuVerdict(pinned: "", presented: "aabb"), .mismatch)
    }

    func testSha256OfTheEmptyInputIsTheKnownVector() {
        XCTAssertEqual(
            sha256FingerprintHex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testSha256OfAbcIsTheKnownVector() {
        XCTAssertEqual(
            sha256FingerprintHex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSha256OutputIsLowercase64HexChars() {
        let out = sha256FingerprintHex(Data([0x00, 0x7F, 0xFF]))
        XCTAssertEqual(out.count, 64)
        XCTAssertEqual(out, out.lowercased())
        XCTAssertTrue(out.allSatisfy(\.isHexDigit))
    }
}
