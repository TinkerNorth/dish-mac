// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// A pad gets an audio route only when the match is unambiguous, and the
/// diagnostics learn why when it is not; the source re-reads the HAL.
final class PadAudioRoutesTests: XCTestCase {

    private func function(_ family: PadFamily, id: UInt32) -> PadAudioFunction {
        let name = family == .dualSense ? "DualSense Wireless Controller" : "Wireless Controller"
        return PadAudioFunction(
            device: AudioDeviceFacts(
                id: id,
                uid: "uid-\(id)",
                name: name,
                isUSB: true,
                inputChannels: 1,
                outputChannels: family == .dualSense ? 4 : 2
            ),
            family: family
        )
    }

    func testOnePadAndOneFunctionOfItsFamilyRoute() throws {
        let routes = padAudioRoutes(pads: [AudioRouteCandidate(slotId: "ds", family: .dualSense)], functions: [function(.dualSense, id: 7)])
        let route = try XCTUnwrap(routes["ds"])
        XCTAssertEqual(route.verdict, .routed)
        XCTAssertEqual(route.function?.device.id, 7)
    }

    func testTwoPadsOfOneFamilyRouteNothing() {
        let pads = [AudioRouteCandidate(slotId: "a", family: .dualSense), AudioRouteCandidate(slotId: "b", family: .dualSense)]
        let routes = padAudioRoutes(pads: pads, functions: [function(.dualSense, id: 1), function(.dualSense, id: 2)])
        XCTAssertEqual(routes["a"]?.verdict, .padNameShared)
        XCTAssertEqual(routes["b"]?.verdict, .padNameShared)
        XCTAssertNil(routes["a"]?.function)
    }

    func testTwoFunctionsForOnePadRouteNothing() {
        let routes = padAudioRoutes(
            pads: [AudioRouteCandidate(slotId: "ds", family: .dualSense)],
            functions: [function(.dualSense, id: 1), function(.dualSense, id: 2)]
        )
        XCTAssertEqual(routes["ds"]?.verdict, .endpointNameShared)
    }

    func testFamiliesDoNotCrossAndOtherPadsHaveNoFunction() {
        let pads = [
            AudioRouteCandidate(slotId: "ds", family: .dualSense),
            AudioRouteCandidate(slotId: "ds4", family: .dualShock4),
            AudioRouteCandidate(slotId: "xbox", family: .xbox),
            AudioRouteCandidate(slotId: "pad", family: .other)
        ]
        let routes = padAudioRoutes(pads: pads, functions: [function(.dualShock4, id: 3)])
        XCTAssertEqual(routes["ds4"]?.verdict, .routed)
        XCTAssertEqual(routes["ds"]?.verdict, .noAudioFunction, "a DualSense on Bluetooth, or not yet plugged in")
        XCTAssertEqual(routes["xbox"]?.verdict, .familyWithoutAudio, "nothing a Mac could route")
        XCTAssertEqual(routes["pad"]?.verdict, .familyWithoutAudio)
    }

    @MainActor
    func testTheSourceReadsTheListAndRefreshesOnDemand() {
        var devices = [AudioDeviceFacts(id: 1, uid: "u1", name: "MacBook Pro Speakers", isUSB: false, inputChannels: 0, outputChannels: 2)]
        let source = PadAudioFunctionSource(read: { devices })
        XCTAssertEqual(source.state, [])
        devices.append(function(.dualSense, id: 9).device)
        source.refresh()
        XCTAssertEqual(source.state.map(\.device.id), [9])
    }

    @MainActor
    func testTheSourceListensToTheHALWithoutFailing() {
        let source = PadAudioFunctionSource()
        source.start()
        source.stop()
        source.stop()
    }
}
