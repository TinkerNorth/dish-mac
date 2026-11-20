// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreWLAN
import DishCore
import XCTest
@testable import DishEngine

/// The second cut's facts as the engine folds them: the report naming its
/// pad, each pad's input and output, each host's session and its own view,
/// and the conditions only when a report was prepared.
final class SupportReportFactsTests: XCTestCase {

    private let dualsense = ControllerRecord(id: "sony-dualsense", usb: ["054c:0ce6"], familyId: "dualsense", verification: .verified)

    private func recordedPad() -> PadDiagnostics {
        var pad = PadDiagnostics(slot: ControllerSlot(id: "pad", name: "DualSense Wireless Controller"), wire: nil)
        pad.record = dualsense
        pad.transport = .bluetooth
        return pad
    }

    private func unknownPad() -> PadDiagnostics {
        PadDiagnostics(slot: ControllerSlot(id: "gc", name: "Mystery Pad"), wire: nil)
    }

    private func satellite() -> HostDiagnostics {
        HostDiagnostics(
            summary: ConnectionSummary(id: "sat", name: "PC", address: "192.168.1.44", live: .connected, boundSlotId: "pad"),
            facts: HostSessionFacts.resting(id: "sat")
        )
    }

    private func moonlight(pads: [MoonlightPadFacts], rtt: Int64?) -> HostDiagnostics {
        let info = MoonlightXml.serverInfo("<root status_code=\"200\"><hostname>den</hostname><appversion>0.23.1</appversion></root>")
        return HostDiagnostics(
            summary: ConnectionSummary(id: "ml", name: "Den", address: "10.0.0.7", live: .connected, boundSlotId: nil, kind: .moonlight),
            facts: HostSessionFacts.resting(id: "ml"),
            moonlight: MoonlightHostDiagnostics(phase: .idle, appName: nil, controlRoundTripMs: rtt, info: info, pads: pads)
        )
    }

    private func inputs(capture: FinishedCapture? = nil) -> DiagnosticsBundleInputs {
        DiagnosticsBundleInputs(
            createdAtMs: 1,
            app: BundleAppFacts(name: "dish-mac", version: "1.4.0", build: "1.4.0", flavor: "github"),
            machine: HostMachine(model: "Mac14,2", osMajor: 26, osMinor: 1, arch: "arm64"),
            snapshot: DiagnosticsSnapshot(hosts: [satellite(), moonlight(pads: [], rtt: nil)], pads: [recordedPad(), unknownPad()]),
            events: [],
            outcomes: PadOutcomes(),
            capture: capture,
            hostVersions: [:]
        )
    }

    private static let session = BundleSessionFacts(
        slots: [],
        ack: nil,
        latency: LatencySummary(p50RttMs: nil, p99RttMs: nil, samples: 0, capacity: 1),
        counts: WireCounts()
    )

    // MARK: - The report

    func testAReportNamesItsPadByRecord() {
        var asked = inputs()
        asked.report = SupportReportDraft(category: .noFeedback, text: " No rumble. ", slotId: "pad")
        let report = diagnosticsBundleFacts(asked).report
        XCTAssertEqual(report, SupportReport(category: .noFeedback, text: "No rumble.", controller: "sony-dualsense"))
    }

    func testAReportAboutAPadWithoutARecordNamesItByItsName() {
        var asked = inputs()
        asked.report = SupportReportDraft(category: .notRecognised, text: "Nothing", slotId: "gc")
        XCTAssertEqual(diagnosticsBundleFacts(asked).report?.controller, "Mystery Pad")
    }

    func testAReportAboutNoPadNamesNone() {
        var asked = inputs()
        asked.report = SupportReportDraft(category: .question, text: "Hi", slotId: nil)
        XCTAssertNil(diagnosticsBundleFacts(asked).report?.controller)
    }

    func testWithAReportTheCaptureRidesOnlyThePadItNames() {
        var asked = inputs(capture: FinishedCapture(deviceKey: "named:Mystery Pad", report: "R"))
        asked.report = SupportReportDraft(category: .notRecognised, text: "", slotId: "pad")
        XCTAssertEqual(diagnosticsBundleFacts(asked).pads.map(\.capture), [nil, nil])
        asked.report = SupportReportDraft(category: .notRecognised, text: "", slotId: "gc")
        XCTAssertEqual(diagnosticsBundleFacts(asked).pads.map(\.capture), [nil, "R"])
    }

    func testSaveDiagnosticsHasNoReportNoConditionsAndAsksNoHost() {
        let facts = diagnosticsBundleFacts(inputs())
        XCTAssertNil(facts.report)
        XCTAssertNil(facts.conditions)
        XCTAssertEqual(facts.hosts.map(\.snapshot), [nil, nil])
    }

    // MARK: - The hosts

    func testAPreparedReportCarriesEachHostsOwnViewAndTheConditions() {
        var asked = inputs()
        let document = JSONValue.object(["format": .string(HostSnapshotPolicy.satelliteFormat)])
        let conditions = BundleDeviceConditions(battery: nil, thermal: .nominal, powerSave: false, wifi: nil)
        asked.preparation = ReportPreparation(snapshots: ["sat": .snapshot(document)], conditions: conditions)
        let facts = diagnosticsBundleFacts(asked)
        XCTAssertEqual(facts.hosts.first?.snapshot, BundleHostSnapshot(snapshot: document, error: nil))
        XCTAssertEqual(facts.hosts.last?.snapshot?.snapshot?["format"], .string(HostSnapshotPolicy.moonlightFormat))
        XCTAssertEqual(facts.conditions, conditions)
    }

    func testAnOlderSatelliteFallsBackToWhatItsProbeSaid() {
        var asked = inputs()
        asked.capabilities = ["sat": SatelliteCapabilitiesFacts(
            serverVersion: "2.2.0",
            protocolVersion: 4,
            backends: nil,
            controllerAudio: nil,
            catalogVersion: nil
        )]
        asked.preparation = ReportPreparation(snapshots: ["sat": .failed(.olderSatellite)], conditions: .unknown)
        let snapshot = diagnosticsBundleFacts(asked).hosts.first?.snapshot
        XCTAssertEqual(snapshot?.error, .olderSatellite)
        XCTAssertEqual(snapshot?.snapshot?["serverVersion"], .string("2.2.0"))
    }

    func testASatellitesSessionIsTheOneTheClientCounted() {
        var asked = inputs()
        asked.sessions = ["sat": Self.session]
        XCTAssertEqual(diagnosticsBundleFacts(asked).hosts.first?.session, Self.session)
    }

    func testAMoonlightSessionIsItsPadsAndItsControlRoundTripUncounted() throws {
        let host = moonlight(pads: [MoonlightPadFacts(number: 0, slotId: "pad", type: 2, reports: 5)], rtt: 9)
        let session = try XCTUnwrap(moonlightSession(XCTUnwrap(host.moonlight), records: ["pad": "sony-dualsense"]))
        XCTAssertEqual(
            session.slots,
            [BundleSessionSlot(
                index: 0,
                record: "sony-dualsense",
                requestedType: "2",
                appliedType: nil,
                backend: nil,
                result: nil,
                touchpadMode: nil
            )]
        )
        XCTAssertEqual(session.latency.p50RttMs, 9)
        XCTAssertNil(session.counts)
    }

    func testAMoonlightHostWithNoPadAndNoRoundTripHasNoSession() throws {
        let host = moonlight(pads: [], rtt: nil)
        XCTAssertNil(try moonlightSession(XCTUnwrap(host.moonlight), records: [:]))
    }

    // MARK: - The slots

    func testASlotCarriesWhatWasAskedAndWhatTheSatelliteAnswered() {
        var descriptor = ControllerDescriptor()
        descriptor.ctrlIdx = 1
        descriptor.type = 2
        descriptor.touchpadMode = .ds4
        let answer = SlotApplyAnswer(result: "ok", appliedType: 2, backend: "hidmaestro")
        let slot = sessionSlot(descriptor, record: "sony-dualsense", answer: answer, slugs: [2: "dualsense"])
        XCTAssertEqual(
            slot,
            BundleSessionSlot(
                index: 1,
                record: "sony-dualsense",
                requestedType: "dualsense",
                appliedType: "dualsense",
                backend: "hidmaestro",
                result: "ok",
                touchpadMode: "ds4"
            )
        )
    }

    func testASlotNotYetAnsweredHasNoAppliedFacts() {
        let slot = sessionSlot(ControllerDescriptor(), record: nil, answer: nil, slugs: [:])
        XCTAssertNil(slot.appliedType)
        XCTAssertNil(slot.backend)
        XCTAssertNil(slot.result)
        XCTAssertEqual(slot.requestedType, "0")
    }

    // MARK: - The pads

    func testEachCarriageSendsRumbleWhereItGoes() {
        XCTAssertEqual(rumbleTarget(.ownReport), .directUsb)
        XCTAssertEqual(rumbleTarget(.ownController), .framework)
        XCTAssertEqual(rumbleTarget(.carried), .framework)
        XCTAssertEqual(rumbleTarget(nil), .framework)
        for lost in [RumbleCarriage.carrierHasNoMotors, .noCarrier, .ambiguous, .notCarried] {
            XCTAssertEqual(rumbleTarget(lost), .none, "\(lost)")
        }
    }

    func testAPadReadCarriesItsFramesRateAndLastReport() throws {
        var asked = inputs()
        let report = GamepadReport(buttons: 0x1000)
        let counts = PadOutputCounts(rumble: 3)
        asked.padReadings = ["pad": PadPathReading(latest: LatestInputFacts(frames: 42, last: report), rateHz: 250, output: counts)]
        let pad = try XCTUnwrap(diagnosticsBundleFacts(asked).pads.first)
        XCTAssertEqual(pad.input, BundlePadInput(frames: 42, rateHz: 250, last: report))
        XCTAssertEqual(pad.output?.counts, counts)
    }

    func testAPadWithNoFeedYetHasNoInputAndZeroOutput() throws {
        let pad = try XCTUnwrap(diagnosticsBundleFacts(inputs()).pads.last)
        XCTAssertNil(pad.input)
        XCTAssertEqual(pad.output?.counts, PadOutputCounts())
        XCTAssertNil(pad.output?.speaker, "no audio catalog read, no voice to tell")
    }

    func testThePadsVoicesComeFromTheAudioPlanAndTheRefusals() {
        var pad = recordedPad()
        var plan = AudioPlan.silent
        plan.speakerVoice = true
        let state = ControllerAudioState(plan: plan, micLed: .pulse, playbackRefused: false)
        let route = PadAudioRoute(verdict: .routed, function: nil)
        pad = PadDiagnostics(
            slot: pad.slot,
            wire: nil,
            audio: PadAudioDiagnostics(route: route, state: state, counters: AudioCounters(speakerPlayed: 7))
        )
        let output = bundlePadOutput(pad, counts: PadOutputCounts())
        XCTAssertEqual(output.speaker, BundleVoice(voice: .open, device: "pad", frames: 7))
        XCTAssertEqual(output.haptics, BundleVoice(voice: .closed, device: "pad", frames: 0))
        XCTAssertEqual(output.micLed, "pulse")
    }

    func testAPadsLastDirectWriteRidesItsOutput() {
        var path = SlotInputPath(source: .direct, reason: .macOSReads)
        path.lastWrite = DirectWriteVerdict(route: .interruptOut, reportId: 1, status: 0, atMs: 3)
        path.rumble = .ownReport
        let pad = PadDiagnostics(slot: ControllerSlot(id: "p", name: "Steam Controller"), wire: nil, inputPath: path)
        let output = bundlePadOutput(pad, counts: PadOutputCounts())
        XCTAssertEqual(output.lastWrite, path.lastWrite)
        XCTAssertEqual(output.rumbleTarget, .directUsb)
    }

    // MARK: - The Mac

    func testABatteryWithNoCapacityYetSaysNothing() {
        XCTAssertNil(bundleBattery(HostBattery.Snapshot(percentage: nil, state: .charging)))
    }

    func testABatteryChargingIsCharging() {
        XCTAssertEqual(bundleBattery(HostBattery.Snapshot(percentage: 40, state: .charging)), BundleBattery(level: 40, charging: true))
        XCTAssertEqual(bundleBattery(HostBattery.Snapshot(percentage: 100, state: .full)), BundleBattery(level: 100, charging: false))
    }

    func testEachWifiBandIsItsFrequency() {
        XCTAssertEqual([CWChannelBand.band2GHz, .band5GHz, .band6GHz, .bandUnknown].map(wifiBand), ["2.4", "5", "6", nil])
    }
}
