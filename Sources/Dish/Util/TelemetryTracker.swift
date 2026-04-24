import Foundation
import Combine

/// Mirrors Android's `TelemetryTracker`: samples the input processor once per
/// second and publishes per-second event / send counts for the UI.
@MainActor
final class TelemetryTracker: ObservableObject {

    @Published private(set) var events = 0      // events/sec
    @Published private(set) var sends  = 0      // sends/sec
    @Published private(set) var totalSent: UInt64 = 0

    private weak var processor: GamepadInputProcessor?
    private var timer: Timer?

    init(processor: GamepadInputProcessor) {
        self.processor = processor
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.processor else { return }
            let snap = p.drainTelemetry()
            self.events = snap.events
            self.sends = snap.sends
            self.totalSent = snap.totalSent
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
