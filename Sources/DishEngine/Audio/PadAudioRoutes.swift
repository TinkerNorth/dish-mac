// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Which pad owns which audio function. Core Audio names a device after the
// pad's product string and nothing ties it to a GameController object, so
// the match is by family, and only an unambiguous one counts: exactly one
// pad of the family and exactly one function of it. Two DualSenses on USB
// would route the wrong voice half the time, so they route nothing, and the
// reason is kept for the diagnostics, as dish-android keeps it.

import CoreAudio
import DishKernel
import Foundation

/// Why a pad has no audio route, when it has none.
package enum AudioRouteVerdict: Hashable {
    case routed
    /// The pad's family has no audio of its own that a Mac could route.
    case familyWithoutAudio
    /// A PlayStation pad whose USB audio function is absent: on Bluetooth,
    /// or not plugged in yet.
    case noAudioFunction
    /// More than one pad of the family is attached.
    case padNameShared
    /// More than one audio function of the family is present.
    case endpointNameShared
}

/// A pad's slot as the matcher reads it.
package struct AudioRouteCandidate: Equatable {
    package let slotId: String
    package let family: PadFamily

    package init(slotId: String, family: PadFamily) {
        self.slotId = slotId
        self.family = family
    }
}

package struct PadAudioRoute: Equatable {
    package let verdict: AudioRouteVerdict
    package let function: PadAudioFunction?

    package init(verdict: AudioRouteVerdict, function: PadAudioFunction?) {
        self.verdict = verdict
        self.function = function
    }
}

/// Every attached pad's route, by slot id.
package func padAudioRoutes(pads: [AudioRouteCandidate], functions: [PadAudioFunction]) -> [String: PadAudioRoute] {
    Dictionary(uniqueKeysWithValues: pads.map { pad in
        (pad.slotId, padAudioRoute(for: pad, among: pads, functions: functions))
    })
}

func padAudioRoute(for pad: AudioRouteCandidate, among pads: [AudioRouteCandidate], functions: [PadAudioFunction]) -> PadAudioRoute {
    let family = pad.family
    let siblings = pads.filter { $0.family == family }
    let candidates = functions.filter { $0.family == family }
    guard family == .dualSense || family == .dualShock4 else { return PadAudioRoute(verdict: .familyWithoutAudio, function: nil) }
    guard !candidates.isEmpty else { return PadAudioRoute(verdict: .noAudioFunction, function: nil) }
    guard siblings.count == 1 else { return PadAudioRoute(verdict: .padNameShared, function: nil) }
    guard candidates.count == 1, let function = candidates.first else { return PadAudioRoute(verdict: .endpointNameShared, function: nil) }
    return PadAudioRoute(verdict: .routed, function: function)
}

/// The HAL's pad audio functions, re-read whenever the device list changes.
/// `refresh` is the one reader; the listener only triggers it.
@MainActor
package final class PadAudioFunctionSource: StateSource<[PadAudioFunction]> {

    private let read: () -> [AudioDeviceFacts]
    private var listening = false

    /// `read` defaults to the HAL; tests inject their own device lists.
    package init(read: @escaping () -> [AudioDeviceFacts] = CoreAudioDeviceCatalog.devices) {
        self.read = read
        super.init(initial: padAudioFunctions(in: read()))
    }

    package func refresh() {
        setState(padAudioFunctions(in: read()))
    }

    override package func start() {
        MainActor.assumeIsolated { listen() }
    }

    override package func stop() {
        MainActor.assumeIsolated { unlisten() }
    }

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func listen() {
        guard !listening else { return }
        listening = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            .main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        } == noErr
    }

    private func unlisten() {
        guard listening else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main) { _, _ in }
        listening = false
    }
}
