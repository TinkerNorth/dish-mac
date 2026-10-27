// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import GameController

/// The bridge's side of the input paths: the Direct pads' slots beside
/// GameController's, the carriers' slots hidden and restored, and a Direct
/// pad's rumble and player lights handed to its carrier under the pad's
/// own slot id, so the return paths reach it unchanged.
extension GameControllerInput: InputPathHost {

    /// The controller's gate, from the paths: a carrier's publishes nothing
    /// until its model is picked Standard.
    func admit(_ controller: GCController, id: String) -> PadGate {
        paths.gameControllerAttached(
            id: id,
            name: controller.vendorName ?? controller.productCategory,
            category: categoryOf(controller),
            hasRumble: controller.haptics != nil
        )
    }

    /// A slot already listed keeps its name and battery.
    func upsertSlot(_ slot: Slot) {
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else {
            slots.append(slot)
            return
        }
        slots[index].capabilities = slot.capabilities
        slots[index].family = slot.family
    }

    func showDirectSlot(_ slot: Slot, lane: HidPadLane) {
        let fresh = !slots.contains { $0.id == slot.id }
        upsertSlot(slot)
        guard fresh, slot.capabilities.hasBattery else { return }
        startDirectBatteryHeartbeat(slot.id, lane: lane)
    }

    func hideDirectSlot(_ slotId: String) {
        guard slots.contains(where: { $0.id == slotId }) else { return }
        slots.removeAll { $0.id == slotId }
        processor.remove(deviceId: slotId)
        cancelBatteryTimers(slotId)
    }

    /// A carrier shown again is attached again, through the same path a
    /// fresh controller takes.
    func showCarrierSlot(_ gameControllerId: String, _ shown: Bool) {
        let showing = slots.contains { $0.id == gameControllerId }
        guard shown != showing, let controller = controllersById[gameControllerId] else { return }
        if shown {
            attach(controller)
        } else {
            hideCarrier(gameControllerId)
        }
    }

    private func hideCarrier(_ id: String) {
        slots.removeAll { $0.id == id }
        processor.remove(deviceId: id)
        cancelBatteryTimers(id)
        lastBatteryStatusRaw.removeValue(forKey: id)
    }

    /// The return paths look a slot's controller up by its id, so the
    /// carrier is filed under the Direct pad's id as well as its own.
    func carryOutput(directSlotId: String, via gameControllerId: String?) {
        let carrier = gameControllerId.flatMap { controllersById[$0] }
        guard controllersById[directSlotId] !== carrier else { return }
        actuators.removeValue(forKey: directSlotId)?.shutdown()
        controllersById[directSlotId] = carrier
    }

    func directBatteryChanged(_ slotId: String, _ battery: PadBattery) {
        guard let index = slots.firstIndex(where: { $0.id == slotId }) else { return }
        slots[index].battery = batteryReading(battery)
    }

    /// MSG_BATTERY is a fixed 30 s heartbeat, so the battery the lane last
    /// saw goes out again on that cadence, change or not.
    private func startDirectBatteryHeartbeat(_ slotId: String, lane: HidPadLane) {
        cancelBatteryTimers(slotId)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(kBatteryPollIntervalSec), repeating: .seconds(kBatteryPollIntervalSec))
        timer.setEventHandler { [weak self, weak lane] in
            MainActor.assumeIsolated { self?.repeatDirectBattery(slotId, lane: lane) }
        }
        timer.resume()
        batteryTimers[slotId] = timer
    }

    private func repeatDirectBattery(_ slotId: String, lane: HidPadLane?) {
        guard let battery = lane?.latestBattery else { return }
        processor.publishBattery(deviceId: slotId, level: battery.level, statusRaw: battery.status.rawValue)
    }
}

/// The slot card's pill from a pad's own report: a wired pad's state has
/// no pill of its own.
func batteryReading(_ battery: PadBattery) -> BatteryReading {
    let known = battery.level != ProtocolConstants.batteryLevelUnknown
    let level = known ? Int(battery.level) : nil
    return BatteryReading(level: level, state: batteryChargeState(battery.status))
}

func batteryChargeState(_ status: BatteryStatus) -> BatteryChargeState {
    switch status {
    case .discharging: .discharging
    case .charging: .charging
    case .full: .full
    case .wired, .unknown: .unknown
    }
}
