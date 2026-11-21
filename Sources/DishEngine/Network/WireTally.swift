// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// How many messages of each kind one session sent and received, for the
/// diagnostics bundle. The send path and the receive loop each add one
/// relaxed increment per datagram; nothing on either path reads them, and
/// the main actor reads them only when a report is made.
final class WireTally: @unchecked Sendable {
    private static let sentKinds = WireSentKind.allCases.count
    private static let wordCount = sentKinds + WireReceivedKind.allCases.count

    private let words = UnsafeMutablePointer<Int64>.allocate(capacity: wordCount)

    init() {
        words.initialize(repeating: 0, count: Self.wordCount)
    }

    deinit {
        words.deallocate()
    }

    private func word(_ index: Int) -> AtomicWord {
        AtomicWord(address: words + index)
    }

    /// A type the client never sends counts nowhere.
    func sent(_ msgType: UInt16) {
        guard let kind = wireSentKind(msgType) else { return }
        word(kind.rawValue).fetchAddRelaxed(1)
    }

    func received(_ msgType: UInt16) {
        guard let kind = wireReceivedKind(msgType) else { return }
        word(Self.sentKinds + kind.rawValue).fetchAddRelaxed(1)
    }

    func counts() -> WireCounts {
        let sent = WireSentKind.allCases.map { ($0, Int(word($0.rawValue).loadRelaxed())) }
        let received = WireReceivedKind.allCases.map { ($0, Int(word(Self.sentKinds + $0.rawValue).loadRelaxed())) }
        return WireCounts(sent: Dictionary(uniqueKeysWithValues: sent), received: Dictionary(uniqueKeysWithValues: received))
    }
}
