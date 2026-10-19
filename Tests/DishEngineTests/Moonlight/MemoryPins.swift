// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
@testable import DishEngine

/// The gateway's pin registry in memory, for the suites that run it against a
/// loopback host.
final class MemoryPins: MoonlightPinRegistry {
    private let lock = NSLock()
    private var pins: [String: String] = [:]

    func certPin(host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins[host]
    }

    func setCertPin(host: String, fingerprintHex: String) {
        lock.lock()
        pins[host] = fingerprintHex
        lock.unlock()
    }

    func forgetCertPin(host: String) {
        lock.lock()
        pins.removeValue(forKey: host)
        lock.unlock()
    }
}
