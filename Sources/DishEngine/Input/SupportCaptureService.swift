// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Help support this controller" on the main actor: one capture at a time,
// its sequence driven by the pure reducer, the ring drained on the
// service's own timer while the capture runs. The result stays on the Mac:
// the page copies it for the user to paste.

import DishCore
import DishKernel
import Foundation

package struct SupportCaptureFacts: Equatable {
    package let deviceKey: String
    /// False when the key names no device Dish could look for.
    package let known: Bool
    package let capture: SupportCaptureState

    package init(deviceKey: String, known: Bool, capture: SupportCaptureState) {
        self.deviceKey = deviceKey
        self.known = known
        self.capture = capture
    }
}

/// The last capture the person finished this run, for the diagnostics bundle.
package struct FinishedCapture: Equatable {
    package let deviceKey: String
    /// The text the page copies for an issue: the guided steps' reports.
    package let report: String
    /// The same capture in `usb-descriptors-v1`'s terms.
    package let capture: BundleCapture?

    package init(deviceKey: String, report: String, capture: BundleCapture? = nil) {
        self.deviceKey = deviceKey
        self.report = report
        self.capture = capture
    }
}

/// The two clocks a report at rest is placed by: the uptime the capture's
/// thread stamps it on, and the wall clock the file is written in.
struct CaptureClocks {
    let uptimeNs: () -> UInt64
    let wallMs: () -> Int64

    static let live = CaptureClocks(uptimeNs: { DispatchTime.now().uptimeNanoseconds }, wallMs: wallClockMs)
}

@MainActor
final class SupportCaptureService: StateSource<SupportCaptureFacts?> {
    /// Often enough that a press shows on the page at once.
    static let drainMs = 100

    private let capture: HidReportCapturing
    private let scheduler: InputPathScheduler
    private let clocks: CaptureClocks
    private let relay = SupportRelay()
    private var drainTimer: InputPathTimer?
    /// Counts the captures, so a post from one that ended lands nowhere.
    private var generation = 0
    /// Kept after its page closes; the next finished capture replaces it.
    private(set) var lastFinished: FinishedCapture?

    init(capture: HidReportCapturing, scheduler: InputPathScheduler, clocks: CaptureClocks = .live) {
        self.capture = capture
        self.scheduler = scheduler
        self.clocks = clocks
        super.init(initial: nil)
        relay.service = self
    }

    func begin(deviceKey: String) {
        end()
        guard let target = SupportTarget(deviceKey: deviceKey) else {
            setState(SupportCaptureFacts(deviceKey: deviceKey, known: false, capture: SupportCaptureState()))
            return
        }
        setState(SupportCaptureFacts(deviceKey: deviceKey, known: true, capture: SupportCaptureState()))
        generation += 1
        let events = HidCaptureEvents(found: makeFoundPost(generation), lost: makeLostPost(generation))
        capture.start(target: target, events: events)
        drainTimer = scheduler.every(ms: Self.drainMs) { [weak self] in self?.drain() }
    }

    /// Next and Skip; the last step stops the capture and keeps the result,
    /// as the text for an issue and in `usb-descriptors-v1`'s terms.
    func send(_ event: SupportCaptureEvent) {
        takeRestOnLeavingIt(event)
        reduce(event)
        guard let facts = state, facts.capture.phase == .finished else { return }
        let report = supportReportText(facts.capture)
        lastFinished = FinishedCapture(deviceKey: facts.deviceKey, report: report, capture: bundleCapture(facts.capture))
        stopCapturing()
    }

    /// Moving on from the first step takes what the capture held at rest,
    /// placed on the wall clock; a skip takes none.
    private func takeRestOnLeavingIt(_ event: SupportCaptureEvent) {
        guard event == .next, state?.capture.step == .atRest else { return }
        let held = restReports(capture.restReports(), nowUptimeNs: clocks.uptimeNs(), nowWallMs: clocks.wallMs())
        reduce(.restTaken(held))
    }

    func end() {
        stopCapturing()
        setState(nil)
    }

    func drain() {
        let reports = capture.drain()
        guard !reports.isEmpty else { return }
        reduce(.reports(reports))
    }

    private func reduce(_ event: SupportCaptureEvent) {
        guard let facts = state else { return }
        let next = reduceSupportCapture(facts.capture, event)
        setState(SupportCaptureFacts(deviceKey: facts.deviceKey, known: facts.known, capture: next))
    }

    private func stopCapturing() {
        drainTimer?.cancel()
        drainTimer = nil
        capture.stop()
    }

    // MARK: - Hops to the main actor

    private func posted(_ event: SupportCaptureEvent, generation: Int) {
        guard generation == self.generation else { return }
        reduce(event)
    }

    private func makeFoundPost(_ generation: Int) -> @Sendable (SupportDevice) -> Void {
        { [relay] device in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.service?.posted(.deviceFound(device), generation: generation) } }
        }
    }

    private func makeLostPost(_ generation: Int) -> @Sendable () -> Void {
        { [relay] in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.service?.posted(.deviceLost, generation: generation) } }
        }
    }
}

/// The service, weakly, for a closure the capture's thread runs.
final class SupportRelay: @unchecked Sendable {
    weak var service: SupportCaptureService?
}
