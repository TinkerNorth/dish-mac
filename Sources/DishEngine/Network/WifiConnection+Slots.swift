// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The pads one satellite session carries, up to four, each on its own
/// controller index. Every edit goes through `editSlots`, so a change that
/// moves a descriptor converges that index alone over the per-slot routes
/// while live, and the next session PUT carries the whole set.
extension WifiConnection {

    var boundSlotIds: [String] {
        slotTable.boundSlotIds
    }

    var hasRoomForAnotherSlot: Bool {
        slotTable.hasRoom
    }

    func controllerIndex(of slotId: String) -> Int? {
        slotTable.controllerIndex(of: slotId)
    }

    func slotId(at index: Int) -> String? {
        slotTable.slotId(at: index)
    }

    func descriptor(for slotId: String) -> ControllerDescriptor? {
        slotTable.descriptor(for: slotId)
    }

    /// The whole desired controller set for a session PUT, in index order.
    var desiredDescriptors: [ControllerDescriptor] {
        slotTable.descriptors
    }

    func desiredSlots() -> [DesiredSlot] {
        slotTable.desiredSlots()
    }

    var wantsMouseControl: Bool {
        slotTable.wantsMouseControl
    }

    func isSlotApplied(_ slotId: String) -> Bool {
        slotTable.isApplied(slotId)
    }

    /// Each time the satellite confirms the slot plugged, from now on.
    func applyCountPublisher(of slotId: String) -> AnyPublisher<Int, Never> {
        $slotTable
            .map { $0.applyCount(of: slotId) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Binding

    /// The slot's index, the lowest free one for a new slot; nil when the
    /// satellite already carries four. An attach always asks the satellite
    /// again for that index, even when nothing it declares changed.
    @discardableResult
    func attachSlot(_ slotId: String, controllerType: Int, capabilities: ControllerCapabilities, family: PadFamily = .other) -> Int? {
        let before = slotTable.descriptor(for: slotId)
        let index = editSlots { $0.attach(slotId, controllerType: controllerType, capabilities: capabilities, family: family) }
        guard let index else { return nil }
        let unchanged = before != nil && before == slotTable.descriptor(for: slotId)
        if unchanged { convergeIndices([index]) }
        return index
    }

    /// The belief updates at once; a failed DELETE self-heals via reconcile.
    func detachSlot(_ slotId: String) {
        editSlots { $0.detach(slotId) }
    }

    /// The satellite confirmed the slot plugged.
    func markSlotApplied(_ slotId: String) {
        editSlots { $0.markApplied(slotId) }
    }

    /// The pad's claims changed: its audio function enumerated after the
    /// HID did, or left.
    func setCapabilities(_ capabilities: ControllerCapabilities, for slotId: String) {
        editSlots { $0.setCapabilities(capabilities, for: slotId) }
    }

    /// The type the pad is emulated as.
    func setControllerType(_ type: Int, for slotId: String) {
        editSlots { $0.setControllerType(type, for: slotId) }
    }

    /// The catalog's word on the slot's type; a rung the pick does not use
    /// changes nothing on the wire.
    func setTypeOffersDs4(_ offers: Bool, for slotId: String) {
        editSlots { $0.setTypeOffersDs4(offers, for: slotId) }
    }

    /// The probe's word on mouse control, which every pad's touchpad ladder reads.
    func setHostMouseControl(_ available: Bool) {
        editSlots { $0.hostMouseControl = available }
    }

    /// The switches for a pad with none of its own.
    func setForwardingFlags(_ flags: ForwardingFlags) {
        editSlots { $0.connectionFlags = flags }
    }

    /// Each bound pad's switches, by slot id.
    func setSlotFlags(_ flags: [String: ForwardingFlags]) {
        editSlots { $0.slotFlags = flags }
    }
}
