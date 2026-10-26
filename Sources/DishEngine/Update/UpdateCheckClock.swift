// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

/// When the last update check completed and what the time is now, both in
/// milliseconds since the Unix epoch, for the words "last checked 5 minutes
/// ago". A view reads no clock: this one does, for it.
package struct UpdateCheckTime: Equatable {
    package var lastCheckMs: Int64 = 0
    package var nowMs: Int64 = 0

    package init(lastCheckMs: Int64 = 0, nowMs: Int64 = 0) {
        self.lastCheckMs = lastCheckMs
        self.nowMs = nowMs
    }
}

/// Re-reads the time once a minute while a page that words the last check
/// is on screen, so the words tick; still otherwise. A completed check is
/// read at once.
@MainActor
final class UpdateCheckClock: StateSource<UpdateCheckTime> {

    static let tickSeconds = 60

    private let lastCheckMs: () -> Int64
    private let now: () -> Int64
    private var viewers = 0
    private var timer: DispatchSourceTimer?

    init(lastCheckMs: @escaping () -> Int64, now: @escaping () -> Int64) {
        self.lastCheckMs = lastCheckMs
        self.now = now
        super.init(initial: UpdateCheckTime(lastCheckMs: lastCheckMs(), nowMs: now()))
    }

    var isTicking: Bool {
        timer != nil
    }

    /// A page that words the last check came on screen.
    func show() {
        viewers += 1
        refresh()
        arm()
    }

    /// A page that words it left; the tick stops with the last.
    func hide() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        timer?.cancel()
        timer = nil
    }

    func refresh() {
        setState(UpdateCheckTime(lastCheckMs: lastCheckMs(), nowMs: now()))
    }

    private func arm() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .seconds(Self.tickSeconds), repeating: .seconds(Self.tickSeconds))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.resume()
        timer = source
    }
}
