// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation
import IOKit

/// Whether the Mac's lid is closed. Tests inject a fake; the IOKit one reads
/// the power manager's own flag.
protocol ClamshellStateReading: AnyObject {
    /// A Mac without a lid reads open.
    func lidIsClosed() -> Bool
}

/// `AppleClamshellState` on `IOPMrootDomain`, the flag `ioreg` and `pmset`
/// show. A desktop Mac has no such property, and reads open.
final class IOKitClamshellState: ClamshellStateReading {

    static let rootDomainClass = "IOPMrootDomain"
    static let clamshellKey = "AppleClamshellState"

    func lidIsClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(Self.rootDomainClass))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }
        let property = IORegistryEntryCreateCFProperty(rootDomain, Self.clamshellKey as CFString, kCFAllocatorDefault, 0)
        let value = property?.takeRetainedValue() as? Bool
        return value ?? false
    }
}

/// Remembers, across one sleep, whether a closed lid paused a stream: read as
/// the machine goes to sleep, told once when it wakes.
@MainActor
final class LidWatch {

    private let clamshell: ClamshellStateReading
    private var streamPausedByLid = false
    /// Fires once on the wake after a sleep that closed the lid on a stream.
    let lidPausedStreaming = PassthroughSubject<Void, Never>()

    init(clamshell: ClamshellStateReading) {
        self.clamshell = clamshell
    }

    func noteSleep(streaming: Bool) {
        let lidClosed = clamshell.lidIsClosed()
        streamPausedByLid = lidClosed && streaming
    }

    func noteWake() {
        let tellTheUser = streamPausedByLid
        streamPausedByLid = false
        if tellTheUser { lidPausedStreaming.send(()) }
    }
}
