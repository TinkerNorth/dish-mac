// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The hot path of one Moonlight session: the pad table and the live sender
// under one lock. Input arrives on the controller callback threads, the
// host's motion requests on the transport's queue, and the table's changes
// on the main actor; all three read and write the same table. What to send
// is decided under the lock and sent outside it, so a sender that takes its
// own lock never nests inside this one.

import DishCore
import Foundation

/// What the link sends on: the control session in production, a recorder in tests.
protocol MoonlightPadSending: AnyObject {
    func sendControllerState(_ frame: MoonlightInput.PadFrame)
    func sendControllerArrival(_ arrival: MoonlightInput.PadArrival)
    func sendControllerReplug(number: UInt8, otherPadsMask: UInt16, arrival: MoonlightInput.PadArrival)
    func sendControllerTouch(controller: UInt8, emission: MoonlightTouchEmission)
    func sendControllerMotion(controller: UInt8, type: UInt8, x: Float, y: Float, z: Float)
    func sendControllerBattery(controller: UInt8, state: UInt8, percentage: UInt8)
}

extension MoonlightControlSession: MoonlightPadSending {}

final class MoonlightPadLink: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var table = MoonlightPadTable()
    private var sender: MoonlightPadSending?
    private var sentByNumber = [Int](repeating: 0, count: MoonlightProtocol.maxPads)
    private let nowNs: () -> Int64

    init(nowNs: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds) }) {
        self.nowNs = nowNs
    }

    // MARK: - The table

    var pads: [MoonlightPadTable.Pad] {
        locked { table.pads }
    }

    var activeMask: UInt16 {
        locked { table.activeMask }
    }

    var count: Int {
        locked { table.count }
    }

    var isFull: Bool {
        locked { table.isFull }
    }

    var isLive: Bool {
        locked { sender != nil }
    }

    func pad(for slotId: String) -> MoonlightPadTable.Pad? {
        locked { table.pad(for: slotId) }
    }

    /// The slot behind the number a host event names; a number no session
    /// can carry names none.
    func slot(forController controller: UInt16) -> String? {
        guard controller < UInt16(MoonlightProtocol.maxPads) else { return nil }
        return locked { table.slot(for: UInt8(controller)) }
    }

    func motionWanted(_ slotId: String) -> Bool {
        locked { table.motionWanted(slotId) }
    }

    /// Frames sent for the pad at this number since the link came up.
    func reportsSent(for number: UInt8) -> Int {
        guard Int(number) < MoonlightProtocol.maxPads else { return 0 }
        return locked { sentByNumber[Int(number)] }
    }

    /// Take the lowest free number for the slot, announcing the pad at rest
    /// when the link is live; the pad a slot holds already is kept and not
    /// announced again. Nil when the session carries its four.
    func acquire(_ slotId: String, as wanted: MoonlightAnnouncedPad) -> MoonlightPadTable.Pad? {
        os_unfair_lock_lock(&lock)
        let held = table.pad(for: slotId)
        let pad = table.acquire(slotId, as: wanted)
        let live = sender
        let mask = table.activeMask
        os_unfair_lock_unlock(&lock)
        if let pad, held == nil, let live { announce(pad, mask: mask, on: live) }
        return pad
    }

    /// Drop the slot's pad. The frame that names its number with its bit
    /// cleared is the unplug (Wolf drops the pad on that frame and on no
    /// other), and the number is free once it has gone out. Returns how
    /// many pads remain.
    func release(_ slotId: String) -> Int {
        os_unfair_lock_lock(&lock)
        let number = table.release(slotId)
        let remaining = table.count
        let mask = table.activeMask
        let live = sender
        os_unfair_lock_unlock(&lock)
        if let number, let live { live.sendControllerState(MoonlightInput.PadFrame(controller: number, activeMask: mask)) }
        return remaining
    }

    /// The slot's pad as another pad under its number. On a live link the
    /// host unplugs the number and plugs the new pad in, then hears it at
    /// rest; before, only the table changes and the install announces it.
    func reannounce(_ slotId: String, as wanted: MoonlightAnnouncedPad) -> MoonlightPadTable.Pad? {
        os_unfair_lock_lock(&lock)
        let pad = table.reannounce(slotId, as: wanted)
        let mask = table.activeMask
        let live = sender
        os_unfair_lock_unlock(&lock)
        if let pad, let live {
            live.sendControllerReplug(number: pad.number, otherPadsMask: mask & ~(UInt16(1) << UInt16(pad.number)), arrival: pad.arrival)
            live.sendControllerState(MoonlightInput.PadFrame(controller: pad.number, activeMask: mask))
        }
        return pad
    }

    // MARK: - The session

    /// Adopt a connected session: every held pad is announced on it, at rest.
    func install(_ live: MoonlightPadSending) {
        os_unfair_lock_lock(&lock)
        sender = live
        let pads = table.pads
        let mask = table.activeMask
        os_unfair_lock_unlock(&lock)
        for pad in pads {
            announce(pad, mask: mask, on: live)
        }
    }

    /// The session is gone: the pads stay claimed, what the host asked of
    /// or was told about them is forgotten, the counts start over.
    func clear() {
        os_unfair_lock_lock(&lock)
        sender = nil
        table.forgetHostState()
        sentByNumber = [Int](repeating: 0, count: MoonlightProtocol.maxPads)
        os_unfair_lock_unlock(&lock)
    }

    private func announce(_ pad: MoonlightPadTable.Pad, mask: UInt16, on live: MoonlightPadSending) {
        live.sendControllerArrival(pad.arrival)
        live.sendControllerState(MoonlightInput.PadFrame(controller: pad.number, activeMask: mask))
    }

    // MARK: - HOT PATH (controller callback threads)

    func sendReport(_ slotId: String, _ report: GamepadReport) {
        os_unfair_lock_lock(&lock)
        guard let live = sender, let frame = table.frame(slotId, report: report) else {
            os_unfair_lock_unlock(&lock)
            return
        }
        sentByNumber[Int(frame.controller)] += 1
        os_unfair_lock_unlock(&lock)
        live.sendControllerState(frame)
    }

    func sendTouchpad(_ slotId: String, sample: TouchpadSample) {
        os_unfair_lock_lock(&lock)
        guard let live = sender, let out = table.touch(slotId, sample: sample) else {
            os_unfair_lock_unlock(&lock)
            return
        }
        if out.replay != nil { sentByNumber[Int(out.controller)] += 1 }
        os_unfair_lock_unlock(&lock)
        if let replay = out.replay { live.sendControllerState(replay) }
        for emission in out.emissions {
            live.sendControllerTouch(controller: out.controller, emission: emission)
        }
    }

    func sendMotion(_ slotId: String, _ sample: MotionSample) {
        os_unfair_lock_lock(&lock)
        guard let live = sender else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let packets = table.motion(slotId, sample: sample, nowNs: nowNs())
        os_unfair_lock_unlock(&lock)
        for packet in packets {
            live.sendControllerMotion(controller: packet.controller, type: packet.type, x: packet.x, y: packet.y, z: packet.z)
        }
    }

    func sendBattery(_ slotId: String, level: UInt8, status: BatteryStatus) {
        os_unfair_lock_lock(&lock)
        guard let live = sender, let out = table.battery(slotId, level: level, status: status) else {
            os_unfair_lock_unlock(&lock)
            return
        }
        os_unfair_lock_unlock(&lock)
        live.sendControllerBattery(controller: out.controller, state: out.state, percentage: out.percentage)
    }

    /// MOTION_EVENT from the host, on the transport's queue.
    func onMotionRequest(controller: UInt16, rateHz: UInt16, type: UInt8) {
        guard controller < UInt16(MoonlightProtocol.maxPads) else { return }
        os_unfair_lock_lock(&lock)
        table.onMotionRequest(controller: UInt8(controller), rateHz: rateHz, type: type)
        os_unfair_lock_unlock(&lock)
    }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
