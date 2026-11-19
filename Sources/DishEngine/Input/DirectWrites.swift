// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The last Direct write's verdict per pad: the writer posts it from
// whichever thread wrote (the HID reader's thread for the Switch start, an
// output's own queue for a Steam Controller and an XUSB pad), and the main
// actor takes the newest on its own ticks. The post takes no lock, so the
// reader's thread stays inside its lock law.

import DishCore
import Foundation

/// One verdict, boxed so it can ride a mailbox.
final class DirectWriteMail {
    let verdict: DirectWriteVerdict

    init(_ verdict: DirectWriteVerdict) {
        self.verdict = verdict
    }
}

final class DirectWrites: @unchecked Sendable {
    private let mailbox = Mailbox<DirectWriteMail>()
    private let clockMs: @Sendable () -> Int64

    init(clockMs: @escaping @Sendable () -> Int64 = wallClockMs) {
        self.clockMs = clockMs
    }

    /// One write's answer, stamped now.
    func record(route: ControllerOutputRoute, reportId: UInt8, status: Int32) {
        mailbox.post(DirectWriteMail(DirectWriteVerdict(route: route, reportId: reportId, status: status, atMs: clockMs())))
    }

    /// The newest verdict since the last take, or nil.
    func take() -> DirectWriteVerdict? {
        mailbox.take()?.verdict
    }
}

/// Milliseconds since the Unix epoch.
@Sendable
func wallClockMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
