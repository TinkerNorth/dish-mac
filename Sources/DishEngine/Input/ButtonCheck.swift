// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Check the buttons" on the main actor: one walk at a time over a generic
// pad's declared sources, its assignments written to the model's stored
// remap as they land (the paths swap the lane's table from the store), and
// the lane's gate asked for each next raw change.

import DishCore
import DishKernel
import Foundation

/// Where the page's walk stands.
package enum ButtonCheckPhase: Equatable {
    /// The pad is gone, or never was.
    case missing
    /// The pad is read by a fixed decoder (a Nintendo pad) or by macOS.
    case notRemappable
    case walking(RemapAssignState)
}

package struct ButtonCheckFacts: Equatable {
    package let slotId: String
    package let name: String
    package let phase: ButtonCheckPhase

    package init(slotId: String, name: String, phase: ButtonCheckPhase) {
        self.slotId = slotId
        self.name = name
        self.phase = phase
    }
}

@MainActor
final class ButtonCheck: StateSource<ButtonCheckFacts?> {

    let store: JoystickRemapStore
    private var lane: HidPadLane?
    private var walk: RemapAssignState?

    init(store: JoystickRemapStore) {
        self.store = store
        super.init(initial: nil)
    }

    /// From what is stored, else the model's own order; a pad Dish does not
    /// read through a declared layout gets no walk.
    func begin(slotId: String, name: String, lane: HidPadLane?, present: Bool) {
        end()
        guard let lane, case let .hidGamepad(layout) = lane.candidate.decoder else {
            setState(ButtonCheckFacts(slotId: slotId, name: name, phase: present ? .notRemappable : .missing))
            return
        }
        let defaults = defaultRemap(order: layout.order)
        let candidate = lane.candidate
        let stored = store.remap(vendorId: candidate.vendorId, productId: candidate.productId)
        self.lane = lane
        walk = RemapAssignState(remap: stored ?? defaults, defaults: defaults)
        lane.gate.listenForCapture()
        publish(slotId: slotId, name: name)
    }

    func send(_ event: RemapAssignEvent) {
        guard let lane, let walk else { return }
        let reduction = reduceRemapAssign(walk, event)
        self.walk = reduction.next
        for effect in reduction.effects {
            run(effect, lane: lane)
        }
        publish(slotId: lane.slotId, name: state?.name ?? lane.candidate.name)
    }

    /// A raw change from the lane the walk listens on.
    func captured(slotId: String, _ capture: RawCapture) {
        guard lane?.slotId == slotId else { return }
        send(.captured(capture))
    }

    /// The walk's pad went away: the page says so.
    func laneGone(slotId: String) {
        guard lane?.slotId == slotId, let name = state?.name else { return }
        end()
        setState(ButtonCheckFacts(slotId: slotId, name: name, phase: .missing))
    }

    func end() {
        lane?.gate.closeCapture()
        lane = nil
        walk = nil
        setState(nil)
    }

    private func run(_ effect: RemapAssignEffect, lane: HidPadLane) {
        let candidate = lane.candidate
        switch effect {
        case let .store(remap): store.setRemap(remap, vendorId: candidate.vendorId, productId: candidate.productId)
        case .clearStored: store.clearRemap(vendorId: candidate.vendorId, productId: candidate.productId)
        case .listen: lane.gate.listenForCapture()
        case .stopListening: lane.gate.closeCapture()
        }
    }

    private func publish(slotId: String, name: String) {
        guard let walk else { return }
        setState(ButtonCheckFacts(slotId: slotId, name: name, phase: .walking(walk)))
    }
}

/// The stored remap of a generic pad's model as its lane's table; nil, the
/// model's own order, for a pad nothing is stored for or one Dish reads
/// with a fixed decoder.
func remapTable(for candidate: HidPadCandidate, in remaps: [String: JoystickRemap]) -> HidRemapTable? {
    guard case .hidGamepad = candidate.decoder else { return nil }
    return remaps[usbPathKey(vendorId: candidate.vendorId, productId: candidate.productId)].map(HidRemapTable.init(remap:))
}
