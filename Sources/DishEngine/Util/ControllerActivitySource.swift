// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import Foundation

/// Whether a controller was used inside the idle window: the hot path
/// stamps the last input, a tick reads it against the window. The clocks
/// are injected so a test drives the tick itself.
@MainActor
final class ControllerActivitySource: StateSource<Bool> {

    private let lastInputMs: () -> Int64
    private let timeoutMs: () -> Int64
    private let now: () -> Int64
    private let tickIntervalMs: Int
    private var timer: DispatchSourceTimer?

    init(
        lastInputMs: @escaping () -> Int64,
        timeoutMs: @escaping () -> Int64,
        now: @escaping () -> Int64,
        tickIntervalMs: Int = 1000
    ) {
        self.lastInputMs = lastInputMs
        self.timeoutMs = timeoutMs
        self.now = now
        self.tickIntervalMs = tickIntervalMs
        super.init(initial: controllerActive(lastInputMs: lastInputMs(), nowMs: now(), timeoutMs: timeoutMs()))
    }

    /// The kernel's lifecycle hooks are not isolated; the source is driven
    /// from the main actor, where its callers already are.
    override func start() {
        MainActor.assumeIsolated { startTicking() }
    }

    override func stop() {
        MainActor.assumeIsolated { stopTicking() }
    }

    private func startTicking() {
        tick()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(tickIntervalMs), repeating: .milliseconds(tickIntervalMs))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        source.resume()
        timer = source
    }

    private func stopTicking() {
        timer?.cancel()
        timer = nil
    }

    /// One evaluation of the window; equal values do not re-emit.
    func tick() {
        setState(controllerActive(lastInputMs: lastInputMs(), nowMs: now(), timeoutMs: timeoutMs()))
    }
}

/// The monotonic millisecond clock the hot path stamps with.
func uptimeMs() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}
