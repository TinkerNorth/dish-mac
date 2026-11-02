// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Where a slot's input goes and which of its streams may flow: the sink
/// (a satellite session, or a pad on a Moonlight host) and the switches in
/// force for that controller, global and per-controller folded together on
/// the main actor.
struct Route {
    let sink: any InputSink
    let flags: ForwardingFlags
}

/// One pad on one satellite: the connection and the controller index the
/// satellite's return paths name it by.
struct SatellitePadKey: Hashable {
    let connectionId: String
    let controllerIndex: Int
}

/// A satellite's side of the same table: the slot bound to one of its
/// controller indices and the switches in force for that controller, for
/// the return paths. A Moonlight host's feedback finds the slot through the
/// pad number instead and reads the slot's own route.
struct BoundSlotRoute {
    let slotId: String
    let flags: ForwardingFlags
}

/// The two views of one binding table, rebuilt together so they can never
/// disagree.
struct RoutingSnapshot {
    var bySlot: [String: Route] = [:]
    var bySatellitePad: [SatellitePadKey: BoundSlotRoute] = [:]
}

/// The routing table for the cold readers: written on the main actor when
/// bindings, the pool or a switch change; read by the main actor's battery
/// and release sends, by the Moonlight feedback and by the tests. No report
/// reads it: each pad's feed holds its own route.
final class RoutingTable: @unchecked Sendable {
    private var snapshot = RoutingSnapshot()
    private var lock = TrackedLock(os_unfair_lock_s(), "routing.table")

    func get(_ slotId: String) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.bySlot[slotId]
    }

    func boundSlot(of pad: SatellitePadKey) -> BoundSlotRoute? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.bySatellitePad[pad]
    }

    func current() -> RoutingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func set(_ next: RoutingSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshot = next
    }
}

/// From the main actor's routing to the hot path: one snapshot fills the
/// table and gives every pad's feed its resolved route, so a report reads
/// no table and takes no lock on its way to the wire.
final class InputRouting: @unchecked Sendable {
    let table = RoutingTable()

    /// Publishes `snapshot` to the table and to every feed, a satellite pad
    /// resolved to its connection's live client. Call it again when a
    /// connection's client changes.
    @MainActor
    func publish(_ snapshot: RoutingSnapshot, to processor: GamepadInputProcessor) {
        table.set(snapshot)
        let routes = resolvedRoutes(snapshot)
        processor.route { routes[$0] }
    }

    @MainActor
    func republish(to processor: GamepadInputProcessor) {
        publish(table.current(), to: processor)
    }
}

/// Each slot's route with a satellite pad resolved to the live client of
/// its connection, so a report never looks the client up; a pad whose
/// connection has no client has no route until the connection gets one.
@MainActor
func resolvedRoutes(_ snapshot: RoutingSnapshot) -> [String: Route] {
    snapshot.bySlot.compactMapValues { route in
        guard let pad = route.sink as? SatellitePadSink else { return route }
        guard let client = pad.connection.client else { return nil }
        return Route(sink: SatelliteClientSink(client: client, controllerIndex: pad.controllerIndex), flags: route.flags)
    }
}
