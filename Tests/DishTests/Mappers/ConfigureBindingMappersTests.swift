// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI
import XCTest
@testable import Dish

/// Configure binding: the page waits for its draft, names a pad that left,
/// lists the destinations by kind with the pick marked, offers a switch for
/// each feature the pad has, the type once a destination is picked, counts
/// what carries, words the bar by the binding it opened on, and draws the
/// apply step by step.
final class ConfigureBindingMappersTests: XCTestCase {

    private typealias Fix = MapperFixtures

    private func facts(_ draft: BindingDraft?, candidate: ControllerSlot? = nil, progress: ApplyProgress = .idle) -> ShellFacts {
        var facts = ShellFacts()
        facts.binding.draft = draft
        facts.binding.candidate = candidate ?? draft.map { _ in Fix.pad() }
        facts.binding.progress = progress
        return facts
    }

    /// Den carries another pad, so only Loft and the Moonlight host have room.
    private let taken = ConnectionSummary(id: "den", name: "Den", address: "192.0.2.10", live: .connected, boundSlotId: "other")

    private func page(_ facts: ShellFacts, slots: [ControllerSlot] = [Fix.pad()]) -> ConfigureBindingPageState {
        configureBindingPageState(BindingInputs(slotId: "pad", slots: slots, connections: [taken, Fix.loft, Fix.host], facts: facts))
    }

    private func editor(_ facts: ShellFacts) throws -> BindingEditorState {
        let content = page(facts).content
        guard case let .editing(editor) = content else { return try XCTUnwrap(nil, "an editor, got \(content)") }
        return editor
    }

    private let unbound = BindingDraft(slotId: "pad", original: BindingChoice())

    func testThePageWaitsForItsDraft() {
        XCTAssertEqual(page(facts(nil)).content, .opening)
    }

    func testAPadThatLeftIsNamedMissing() {
        XCTAssertEqual(
            page(facts(unbound), slots: []).content,
            .missing(title: "No controllers connected", body: "Plug one in, then pick where it goes")
        )
    }

    func testTheDestinationsSplitByKindAndMarkThePick() throws {
        let picked = reduce(unbound, .chooseDestination("loft"))
        let destination = try editor(facts(picked)).destination
        XCTAssertEqual(destination.satellites.map(\.id), ["loft"], "a satellite carrying another pad is not offered")
        XCTAssertEqual(destination.satellites.first?.selected, true)
        XCTAssertEqual(destination.satellites.first?.subtitle, "192.0.2.11 • UDP 9876")
        XCTAssertEqual(destination.moonlight.map(\.subtitle), ["Moonlight host · 10.0.0.5"])
        XCTAssertEqual(destination.moonlightTitle, "Moonlight hosts")
        XCTAssertNil(destination.empty)
    }

    func testWithNowhereToBindThePageSendsYouToConnections() {
        let section = destinationSection(Fix.pad(), draft: unbound, connections: [taken])
        XCTAssertEqual(
            section.empty,
            EmptyHostsState(
                title: "No hosts found",
                message: "Pair a Satellite or a Moonlight host on Connections, then come back to bind DualSense."
            )
        )
        XCTAssertEqual(section.manage, "Manage destinations ›")
    }

    func testTheFunctionsFollowThePadsHardwareAndTheDraft() {
        var candidate = Fix.pad()
        candidate.preferences = SlotPreferences(rumble: false)
        let functions = functionsSection(candidate)
        XCTAssertEqual(functions.switches.map(\.title), ["Motion", "Rumble"])
        XCTAssertEqual(functions.switches.map(\.on), [true, false])
        XCTAssertEqual(functions.touchpad?.options.map(\.enabled), [true, true, false], "the mouse waits for the host's word")
        XCTAssertNil(functions.nothing)
        XCTAssertEqual(
            functionsSection(ControllerSlot(id: "pad", name: "Pad")).nothing,
            "Nothing to tune for this combination — see why on the right. The pad is ready to bind."
        )
    }

    func testEachSwitchSendsItsDraftEvent() {
        XCTAssertEqual(switchEvent(.motion, on: false), .setMotion(false))
        XCTAssertEqual(switchEvent(.rumble, on: true), .setRumble(true))
        XCTAssertEqual(switchEvent(.touchpad, on: false), .setTouchpad(.off))
        XCTAssertEqual(switchEvent(.touchpad, on: true), .setTouchpad(.pad))
        XCTAssertEqual(switchEvent(.mic, on: true), .setMic(true))
        XCTAssertEqual(switchEvent(.speaker, on: false), .setSpeaker(false))
    }

    func testTheTypeAppearsOnceADestinationIsPicked() {
        XCTAssertNil(emulateSection(Fix.pad(), draft: unbound))
        var candidate = Fix.pad(boundTo: Fix.host)
        candidate.emulation = SlotEmulation(type: 1, isOverride: true, offered: [])
        let picked = reduce(reduce(unbound, .chooseDestination(Fix.host.id)), .chooseType(2))
        let section = emulateSection(candidate, draft: picked)
        XCTAssertEqual(section?.options.map(\.label), ["Auto", "Xbox", "PlayStation", "Nintendo"])
        XCTAssertEqual(section?.selected, 2)
    }

    func testWhatCarriesCountsTheLiveRowsOrSaysPending() {
        let available = CapabilityRowModel(feature: .gamepad, label: "Gamepad", verdict: .available, verdictText: "Supported", help: "")
        let off = CapabilityRowModel(feature: .rumble, label: "Rumble", verdict: .off, verdictText: "Off", help: "")
        let pending = CapabilityRowModel(feature: .motion, label: "Motion", verdict: .pending, verdictText: "Pending", help: "")
        XCTAssertEqual(carriesSection([available, off]).summary, "1/2 live")
        XCTAssertEqual(carriesSection([pending]).summary, "pending")
        XCTAssertEqual(carriesSection([available]).rows.first?.color, DishTheme.success)
    }

    func testTheBarIsWordedByTheBindingThePageOpenedOn() {
        let fresh = bindingBar(unbound, progress: .idle)
        XCTAssertNil(fresh.unbind)
        XCTAssertEqual(fresh.apply, "Bind")
        XCTAssertEqual(fresh.hint, "Pick a destination to continue.")
        XCTAssertFalse(fresh.applyEnabled)
        let bound = BindingDraft(slotId: "pad", original: BindingChoice(connectionId: "den"))
        let edit = bindingBar(bound, progress: .idle)
        XCTAssertEqual(edit.unbind, "Unbind")
        XCTAssertEqual(edit.apply, "Apply")
        XCTAssertEqual(edit.hint, "Nothing is sent until you apply.")
        XCTAssertTrue(edit.applyEnabled)
        XCTAssertFalse(bindingBar(bound, progress: .running(.applyingOnHost)).applyEnabled, "one apply at a time")
    }

    func testTheOverlayFollowsTheRunStepByStep() throws {
        XCTAssertNil(applyOverlay(.idle, pad: "DualSense", host: "Den"))
        let waiting = try XCTUnwrap(applyOverlay(.running(.binding), pad: "DualSense", host: "Den"))
        XCTAssertEqual(waiting.heading, "Applying binding…")
        XCTAssertEqual(waiting.steps.map(\.title), ["Binding", "Applying on the host"])
        XCTAssertEqual(waiting.steps.map(\.phase), [.active, .pending])
        XCTAssertEqual(waiting.cancel, "Cancel", "cancellable before the PUT")
        XCTAssertNil(waiting.close)
        let onHost = try XCTUnwrap(applyOverlay(.running(.applyingOnHost), pad: "DualSense", host: "Den"))
        XCTAssertEqual(onHost.steps.map(\.phase), [.done, .active])
        XCTAssertNil(onHost.cancel, "the REST round trip offers no escape")
        let done = try XCTUnwrap(applyOverlay(.done, pad: "DualSense", host: "Den"))
        XCTAssertEqual(done.result, ApplyResultLine(text: "Controller bound — DualSense is live on Den.", color: DishTheme.success))
        XCTAssertEqual(done.close, "Done")
    }

    func testAFailedRunSaysWhyAndMarksTheStepThatFailed() throws {
        let unreachable = try XCTUnwrap(applyOverlay(.failed(.hostUnreachable), pad: "DualSense", host: "Den"))
        XCTAssertEqual(unreachable.steps.map(\.phase), [.done, .failed])
        XCTAssertEqual(unreachable.result?.color, DishTheme.error)
        XCTAssertEqual(unreachable.close, "Close")
        XCTAssertEqual(applyOverlay(.failed(.cancelled), pad: "DualSense", host: "Den")?.steps.map(\.phase), [.failed, .pending])
        XCTAssertEqual(
            failureLine(.hostUnreachable, pad: "DualSense", host: "Den"),
            "Couldn’t reach Den. Make sure it’s on and on your network."
        )
        XCTAssertEqual(failureLine(.rejected, pad: "DualSense", host: "Den"), "Den refused the binding.")
        XCTAssertEqual(
            failureLine(.padGone, pad: "DualSense", host: "Den"),
            "DualSense is no longer available. Unplug and reconnect it, then try again."
        )
        XCTAssertEqual(failureLine(.cancelled, pad: "DualSense", host: "Den"), "Apply cancelled. Nothing was changed.")
    }

    func testTheGuardFollowsTheDraftAndOnlyALandedRunPopsTheOverlay() {
        let edited = reduce(unbound, .setMic(true))
        XCTAssertTrue(page(facts(edited)).dirty)
        XCTAssertFalse(page(facts(unbound)).dirty)
        XCTAssertTrue(page(facts(unbound, progress: .done)).popsOnClose)
        XCTAssertFalse(page(facts(unbound, progress: .failed(.rejected))).popsOnClose)
        XCTAssertEqual(page(facts(unbound)).leave.title, "Leave without applying?")
        XCTAssertEqual(page(facts(unbound)).leave.discard, "Discard")
    }

    func testTheOverlayNamesTheHostByItsTitle() {
        let picked = reduce(unbound, .chooseDestination("loft"))
        XCTAssertEqual(page(facts(picked, progress: .failed(.rejected))).overlay?.result?.text, "Loft refused the binding.")
    }

    func testThePickedDestinationIsMarkedInTheAccentAndFilled() {
        XCTAssertEqual(
            selectionLook(selected: true),
            SelectionLook(glyph: "largecircle.fill.circle", ink: DishTheme.primary, fill: DishTheme.chipFill)
        )
        XCTAssertEqual(selectionLook(selected: false), SelectionLook(glyph: "circle", ink: DishTheme.muted, fill: DishTheme.surfaceDim))
    }
}
