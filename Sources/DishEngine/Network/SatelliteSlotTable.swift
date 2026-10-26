// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One pad a satellite session carries: the controller index it holds there
/// for as long as it stays bound, what it is emulated as, what it has, and
/// whether the satellite confirmed it plugged.
struct SatelliteSlot: Equatable {
    let controllerIndex: Int
    var controllerType: Int
    var capabilities: ControllerCapabilities
    var family: PadFamily
    /// The catalog's word on the pad's type: whether it offers the pad
    /// render. A catalog not read refuses nothing.
    var typeOffersDs4 = true
    /// The satellite confirmed the slot plugged. The desire can exist before
    /// the bitmap bit does, and that gap is not drift.
    var applied = false
}

/// A satellite connection's pads, keyed by slot id, at most
/// `SatelliteSlots.maxPerSatellite` of them. A pad's descriptor reads the
/// switches in force for it (its own over the connection's) and the host's
/// word on mouse control. Pure state: the connection converges whatever an
/// edit changed.
struct SatelliteSlotTable: Equatable {
    private(set) var slots: [String: SatelliteSlot] = [:]
    /// How many times the satellite confirmed each slot plugged, this session
    /// or an earlier one: each is a fresh pad on its side, so the audio lanes
    /// start over. Kept across a detach, so a count never rewinds.
    private(set) var applyCounts: [String: Int] = [:]
    /// The switches for a pad with none of its own.
    var connectionFlags = ForwardingFlags()
    /// Each bound pad's switches, the global ones folded with its own.
    var slotFlags: [String: ForwardingFlags] = [:]
    /// The probe's word on whether the host advertises mouse control; a host
    /// not probed grants nothing.
    var hostMouseControl = false

    /// The bound slots in index order.
    var boundSlotIds: [String] {
        slots.sorted { $0.value.controllerIndex < $1.value.controllerIndex }.map(\.key)
    }

    var hasRoom: Bool {
        SatelliteSlots.lowestFreeIndex(taken: takenIndices) != nil
    }

    private var takenIndices: Set<Int> {
        Set(slots.values.map(\.controllerIndex))
    }

    func controllerIndex(of slotId: String) -> Int? {
        slots[slotId]?.controllerIndex
    }

    func slotId(at index: Int) -> String? {
        slots.first { $0.value.controllerIndex == index }?.key
    }

    func applyCount(of slotId: String) -> Int {
        applyCounts[slotId] ?? 0
    }

    func isApplied(_ slotId: String) -> Bool {
        slots[slotId]?.applied ?? false
    }

    // MARK: - Edits

    /// A bound slot keeps its index and takes the new facts; a new one takes
    /// the lowest free index. Nil when the satellite already carries four.
    @discardableResult
    mutating func attach(_ slotId: String, controllerType: Int, capabilities: ControllerCapabilities, family: PadFamily) -> Int? {
        guard let bound = slots[slotId] else {
            return attachNew(slotId, controllerType: controllerType, capabilities: capabilities, family: family)
        }
        var refreshed = bound
        refreshed.controllerType = controllerType
        refreshed.capabilities = capabilities
        refreshed.family = family
        slots[slotId] = refreshed
        return bound.controllerIndex
    }

    private mutating func attachNew(
        _ slotId: String,
        controllerType: Int,
        capabilities: ControllerCapabilities,
        family: PadFamily
    ) -> Int? {
        guard let index = SatelliteSlots.lowestFreeIndex(taken: takenIndices) else { return nil }
        slots[slotId] = SatelliteSlot(controllerIndex: index, controllerType: controllerType, capabilities: capabilities, family: family)
        return index
    }

    /// The index the slot held, now free; nil when it was not bound.
    @discardableResult
    mutating func detach(_ slotId: String) -> Int? {
        slots.removeValue(forKey: slotId)?.controllerIndex
    }

    mutating func setControllerType(_ type: Int, for slotId: String) {
        slots[slotId]?.controllerType = type
    }

    mutating func setCapabilities(_ capabilities: ControllerCapabilities, for slotId: String) {
        slots[slotId]?.capabilities = capabilities
    }

    mutating func setTypeOffersDs4(_ offers: Bool, for slotId: String) {
        slots[slotId]?.typeOffersDs4 = offers
    }

    /// False, and nothing counted, for a slot that is not bound.
    @discardableResult
    mutating func markApplied(_ slotId: String) -> Bool {
        guard slots[slotId] != nil else { return false }
        slots[slotId]?.applied = true
        applyCounts[slotId, default: 0] += 1
        return true
    }

    /// The session ended: nothing is plugged on the satellite's side.
    mutating func clearApplied() {
        for slotId in slots.keys {
            slots[slotId]?.applied = false
        }
    }

    // MARK: - What the wire is told

    func flags(for slotId: String) -> ForwardingFlags {
        slotFlags[slotId] ?? connectionFlags
    }

    /// The slot as one descriptor: the caps and the touchpad mode say what
    /// the pad has AND the user allows.
    func descriptor(for slotId: String) -> ControllerDescriptor? {
        guard let slot = slots[slotId] else { return nil }
        let flags = flags(for: slotId)
        var descriptor = ControllerDescriptor()
        descriptor.ctrlIdx = slot.controllerIndex
        descriptor.type = UInt8(truncatingIfNeeded: slot.controllerType)
        descriptor.caps = descriptorCaps(slot.capabilities, flags)
        descriptor.touchpadMode = descriptorTouchpadMode(
            slot.capabilities,
            flags,
            typeOffersDs4: slot.typeOffersDs4,
            hostMouseControl: hostMouseControl
        )
        return descriptor
    }

    /// The whole desired controller set for a session PUT, in index order;
    /// empty for a valid zero-controller session.
    var descriptors: [ControllerDescriptor] {
        boundSlotIds.compactMap(descriptor(for:))
    }

    func descriptorsByIndex() -> [Int: ControllerDescriptor] {
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.ctrlIdx, $0) })
    }

    func desiredSlots() -> [DesiredSlot] {
        descriptors.map { DesiredSlot(ctrlIdx: UInt8(truncatingIfNeeded: $0.ctrlIdx), type: $0.type) }
    }

    /// What the satellite confirmed, the belief the ack's bitmap is checked against.
    func appliedSlots() -> [DesiredSlot] {
        desiredSlots().filter { slotId(at: Int($0.ctrlIdx)).map(isApplied) ?? false }
    }

    /// The indices of the slots the satellite has not confirmed.
    var unappliedIndices: Set<Int> {
        Set(slots.values.filter { !$0.applied }.map(\.controllerIndex))
    }

    /// The session-level request a PUT carries: some bound pad's touchpad
    /// picked as the host's mouse. The grant is the satellite's answer.
    var wantsMouseControl: Bool {
        slots.contains { slotId, slot in
            let flags = flags(for: slotId)
            return slot.capabilities.hasTouchpad && flags.touchpad && flags.touchpadPick == .mouse
        }
    }
}

/// The indices whose descriptor appeared, went or changed between two readings.
func changedIndices(_ before: [Int: ControllerDescriptor], _ after: [Int: ControllerDescriptor]) -> Set<Int> {
    Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
}
