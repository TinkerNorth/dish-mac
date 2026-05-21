// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Serialises the `MSG_RUMBLE` / `MSG_LIGHTBAR` return paths so a flood of
/// inbound packets can't spawn an unbounded pile of unstructured `Task`s.
///
/// The problem this replaces: `applyRumble` / `applyLightbar` used to do
/// `Task { @MainActor in … }` per inbound packet. Unstructured `Task`s carry
/// **no ordering guarantee**, so under a fast game (rumble/colour every frame)
/// a stale value could land *after* a newer one and latch on the pad; and the
/// task count was bounded only by inbound packet rate.
///
/// Fix: per-device **last-value-wins coalescing** gated by a `scheduled` set.
/// Each `submit` overwrites the device's pending value; it enqueues a drain
/// only when none is already outstanding for that device. The drain applies
/// the value and clears the flag, so the *next* `submit` is what enqueues the
/// following drain — there is therefore never more than one drain in flight
/// per device. That makes the work both **bounded** (≤ one per device,
/// regardless of inbound packet rate — the original unbounded-`Task` flaw) and
/// **ordered** (a drain is created only after the previous one for that device
/// has run, so two can't race and latch a stale value).
///
/// `Value` is the payload type (an RGB tuple, a rumble triple, …). The owner
/// supplies the `apply` closure at construction; it runs on the main actor.
final class ReturnPathApplier<Value>: @unchecked Sendable {

    /// Runs on the main actor with the freshest value for a device. The owner
    /// resolves `deviceId → GCController` and pokes the hardware here.
    typealias Apply = @MainActor (_ deviceId: String, _ value: Value) -> Void

    private let apply: Apply
    /// Newest un-applied value per device. Guarded by `lock`.
    private var pending: [String: Value] = [:]
    /// Devices with a drain item already queued, so a burst enqueues one item,
    /// not one per packet. Guarded by `lock`.
    private var scheduled: Set<String> = []
    private let lock = NSLock()

    /// `label` is accepted for call-site parity with the previous per-path
    /// dispatch queues; the drain runs on the main actor.
    init(label: String, apply: @escaping Apply) {
        _ = label
        self.apply = apply
    }

    /// Record the newest value for `deviceId` and ensure a single drain is
    /// queued. Safe to call from any thread (the SatelliteClient receive loop,
    /// in practice).
    func submit(deviceId: String, value: Value) {
        lock.lock()
        pending[deviceId] = value
        let needsSchedule = scheduled.insert(deviceId).inserted
        lock.unlock()
        // A drain is already outstanding for this device — it will pick up the
        // value we just wrote. Nothing more to enqueue.
        guard needsSchedule else { return }
        // Exactly one drain per device is ever in flight (the gate above), and
        // the next drain is only created by a `submit` that runs *after* this
        // one's drain cleared `scheduled` — so successive drains for a device
        // can't reorder. The Task count is bounded by the live device count.
        Task { @MainActor [weak self] in
            self?.drain(deviceId: deviceId)
        }
    }

    @MainActor
    private func drain(deviceId: String) {
        // Take the freshest value and clear the in-flight flag together, so a
        // `submit` racing this point either updated `pending` before we read
        // (we apply it) or finds `scheduled` empty and queues a fresh drain.
        lock.lock()
        let value = pending.removeValue(forKey: deviceId)
        scheduled.remove(deviceId)
        lock.unlock()
        guard let value else { return }
        apply(deviceId, value)
    }
}
