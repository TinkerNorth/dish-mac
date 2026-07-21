// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// G7: the TOFU URLSession delegate, driven through REAL TLS handshakes
// against the in-process FakeSatellite — first contact pins, a match
// reconnects, a mismatching pin aborts BEFORE any request reaches the
// server, and the pin survives the abort.

import DishCore
import XCTest
@testable import Dish

final class TofuPinningDelegateTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var store: ConnectionStore!
    private var defaultsName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
    }

    override func tearDown() {
        satellite.stop()
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    /// The production verifier shape: DishCore verdict ladder over the
    /// ConnectionStore pin registry (what `WifiConnectionManager` installs).
    private func makeVerifier() -> PinVerifier {
        let store: ConnectionStore = store
        return { host, der in
            let presented = sha256FingerprintHex(der)
            switch tofuVerdict(pinned: store.certPin(host: host), presented: presented) {
            case .trustFirstUse:
                store.setCertPin(host: host, fingerprintHex: presented)
                return true
            case .match:
                return true
            case .mismatch:
                return false
            }
        }
    }

    /// Fresh session per exchange so every request performs a full TLS
    /// handshake (no session-cache short-circuit around the challenge).
    private func makeSession(verifier: @escaping PinVerifier) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        return URLSession(
            configuration: cfg,
            delegate: TofuPinningDelegate(verifier: verifier),
            delegateQueue: nil
        )
    }

    private func fetchCatalog(verifier: @escaping PinVerifier) async throws -> Int {
        let session = makeSession(verifier: verifier)
        defer { session.finishTasksAndInvalidate() }
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(ports.rest)/api/catalog"))
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func requireTLS() throws {
        if satellite.transport != .https {
            throw XCTSkip("FakeSatellite fell back to plain HTTP here — no TLS handshake to pin")
        }
    }

    func testFirstContactPinsFingerprintAndConnects() async throws {
        try requireTLS()
        XCTAssertNil(store.certPin(host: "127.0.0.1"))

        let status = try await fetchCatalog(verifier: makeVerifier())

        XCTAssertEqual(status, 200)
        XCTAssertEqual(
            store.certPin(host: "127.0.0.1"),
            satellite.certificateFingerprintSHA256Hex,
            "first contact must pin the presented cert's SHA-256 DER fingerprint"
        )
        XCTAssertEqual(satellite.catalogRequests, 1)
    }

    func testMatchingPinReconnects() async throws {
        try requireTLS()
        _ = try await fetchCatalog(verifier: makeVerifier())
        let pinAfterFirst = store.certPin(host: "127.0.0.1")

        let status = try await fetchCatalog(verifier: makeVerifier())

        XCTAssertEqual(status, 200)
        XCTAssertEqual(store.certPin(host: "127.0.0.1"), pinAfterFirst, "a match never rewrites the pin")
        XCTAssertEqual(satellite.catalogRequests, 2)
    }

    func testMismatchAbortsBeforeAnyRequestReachesTheServer() async throws {
        try requireTLS()
        // A pin from "another satellite" (any non-matching fingerprint).
        let wrongPin = String(repeating: "ab", count: 32)
        store.setCertPin(host: "127.0.0.1", fingerprintHex: wrongPin)

        do {
            _ = try await fetchCatalog(verifier: makeVerifier())
            XCTFail("handshake against a mismatching pin must fail")
        } catch {
            // Expected: cancelled handshake surfaces as a transport error.
        }
        XCTAssertEqual(satellite.catalogRequests, 0, "the request must never reach the routed server")
        XCTAssertEqual(store.certPin(host: "127.0.0.1"), wrongPin, "mismatch keeps the stored pin")
    }

    func testEmptyStringPinIsARealPinAndMismatches() async throws {
        try requireTLS()
        // The verdict ladder treats an empty stored pin as a REAL pin (only
        // nil means never-pinned). The store normalizes "" writes to clear —
        // so drive the ladder directly with an injected empty pin to keep the
        // delegate honest against a hand-broken registry.
        final class VerdictBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: TofuVerdict?
            func set(_ verdict: TofuVerdict) {
                lock.lock()
                defer { lock.unlock() }
                value = verdict
            }

            func get() -> TofuVerdict? {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let box = VerdictBox()
        let verifier: PinVerifier = { _, der in
            let verdict = tofuVerdict(pinned: "", presented: sha256FingerprintHex(der))
            box.set(verdict)
            return verdict != .mismatch
        }
        do {
            _ = try await fetchCatalog(verifier: verifier)
            XCTFail("empty-string pin must mismatch")
        } catch {}
        XCTAssertEqual(box.get(), .mismatch)
        XCTAssertEqual(satellite.catalogRequests, 0)
    }
}
