// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish
@testable import DishCore

/// The setup walk as drawn, step by step: the stage pips and the footer
/// follow the step, Input lists the pads or waits for one, Destination
/// lists the paired hosts and the satellites a sweep heard, explains the
/// Local Network prompt before the first scan and offers System Settings
/// after a refusal, Type, Session and Feel ask their questions, Review
/// draws the binding with Bind as the one write, a blocker says why it
/// stopped, and the guard and the overlay follow the walk.
final class SetupMappersTests: XCTestCase {

    private typealias Fix = MapperFixtures

    private let draft = BindingDraft(slotId: "pad", original: BindingChoice())
    private let desk = DiscoveredServer(name: "Desk", ip: "10.0.0.5", machineId: "desk", source: .mdns)

    private func walk(_ events: [SetupWizardEvent]) -> SetupWizardState {
        events.reduce(SetupWizardState()) { reduceSetup($0, $1).state }
    }

    /// Pad picked, `host` chosen, and on to `step`.
    private func walked(to step: SetupStep, host: String = Fix.loft.id, kind: SetupHostKind = .satellite) -> SetupWizardState {
        var state = walk([.pickPad(draft, hostKind: nil), .next, .pickDestination(host, kind)])
        while state.step != step {
            state = reduceSetup(state, .next).state
        }
        return state
    }

    private func page(
        _ setup: SetupWizardState?,
        slots: [ControllerSlot] = [Fix.pad()],
        connections: [ConnectionSummary] = [Fix.loft, Fix.host],
        primed: Bool = true,
        configure: (inout ShellFacts) -> Void = { _ in }
    ) -> SetupPageState {
        var facts = ShellFacts()
        facts.setup = setup
        facts.connections.localNetworkPrimed = primed
        configure(&facts)
        return setupPageState(SetupInputs(slots: slots, connections: connections, facts: facts, openPairing: nil))
    }

    private func content(_ state: SetupPageState) throws -> SetupStepContent {
        try XCTUnwrap(state.walk).content
    }

    // MARK: - The frame

    func testWithNoWalkOpenThePageDrawsNothingYetAndDoesNotGuard() {
        let state = page(nil)
        XCTAssertNil(state.walk)
        XCTAssertFalse(state.guarded)
        XCTAssertEqual(state.leave.title, "Leave setup?")
        XCTAssertEqual(state.leave.message, "Nothing has been sent yet. Your answers will be discarded.")
        XCTAssertEqual(state.leave.keep, "Keep setting up")
    }

    func testTheFirstPageLeadsTheStagesAndContinueWaitsForAPad() throws {
        let walk = try XCTUnwrap(page(SetupWizardState()).walk)
        XCTAssertEqual(walk.stages.map(\.label), ["Input", "Destination", "Binding"])
        XCTAssertEqual(walk.stages.map(\.phase), [.current, .upcoming, .upcoming])
        XCTAssertEqual(walk.subSteps, [], "no sub-steps before the binding stage")
        let footer = SetupFooterState(
            back: "‹ Back",
            backEnabled: false,
            cancel: "Cancel",
            hint: "Step 1 of 3 · Input",
            primary: "Continue ›",
            primaryEnabled: false
        )
        XCTAssertEqual(walk.footer, footer)
        XCTAssertFalse(page(SetupWizardState()).guarded, "a pristine first page loses nothing")
    }

    func testTheBindingStageCountsItsStepsAndReviewsPrimaryIsBind() throws {
        let walk = try XCTUnwrap(page(walked(to: .review)).walk)
        XCTAssertEqual(walk.stages.map(\.phase), [.done, .done, .current])
        XCTAssertEqual(walk.subSteps.map(\.phase), [.done, .done, .current], "Type, Feel, Review for a satellite")
        XCTAssertEqual(walk.footer.hint, "Step 3 of 3 · Review")
        XCTAssertEqual(walk.footer.primary, "Bind")
        XCTAssertTrue(walk.footer.primaryEnabled)
        XCTAssertTrue(walk.footer.backEnabled)
        XCTAssertTrue(page(walked(to: .review)).guarded)
    }

    func testAMoonlightWalkCountsTheSessionAmongItsSteps() throws {
        let walk = try XCTUnwrap(page(walked(to: .session, host: Fix.host.id, kind: .moonlight)).walk)
        XCTAssertEqual(walk.subSteps.map(\.phase), [.done, .current, .upcoming, .upcoming])
        XCTAssertEqual(walk.footer.hint, "Step 3 of 3 · Session")
    }

    func testAnApplyInFlightHoldsTheFooterAndShowsTheOverlay() throws {
        let state = page(walked(to: .review)) { $0.binding.progress = .running(.binding) }
        let walk = try XCTUnwrap(state.walk)
        XCTAssertFalse(walk.footer.primaryEnabled)
        XCTAssertFalse(walk.footer.backEnabled)
        XCTAssertEqual(walk.overlay?.heading, "Applying binding…")
        XCTAssertFalse(state.landed)
    }

    func testALandedApplyEndsTheWalkWhenTheOverlayCloses() {
        let state = page(walked(to: .review)) { $0.binding.progress = .done }
        XCTAssertTrue(state.landed)
        XCTAssertEqual(state.walk?.overlay?.close, "Done")
    }

    // MARK: - Input

    func testInputListsThePadsWithThePickedOneSelected() throws {
        guard case let .input(step) = try content(page(walk([.pickPad(draft, hostKind: nil)]))) else { return XCTFail("input") }
        XCTAssertEqual(step.heading.title, "Which controller?")
        XCTAssertEqual(step.pads.map(\.id), ["pad"])
        XCTAssertEqual(step.pads.first?.look, selectionLook(selected: true))
        XCTAssertNil(step.waiting)
    }

    func testInputWithNoPadWaitsAndSaysHowOneArrives() throws {
        guard case let .input(step) = try content(page(SetupWizardState(), slots: [])) else { return XCTFail("input") }
        XCTAssertEqual(step.heading.title, "Plug your controller in")
        XCTAssertEqual(step.pads, [])
        XCTAssertEqual(
            step.waiting?.message,
            "Into any USB port, or turn on a pad already paired to this machine. "
                + "The system sees it, and it appears here — there is no list to add it to."
        )
    }

    // MARK: - Destination

    func testDestinationListsThePairedHostsAndTheSatellitesASweepHeard() throws {
        let state = page(walked(to: .destination)) { $0.connections.discovered = [self.desk] }
        guard case let .destination(step) = try content(state) else { return XCTFail("destination") }
        XCTAssertEqual(step.heading, SetupHeading(title: "Which PC?", subtitle: "Pick the PC this controller should drive."))
        XCTAssertEqual(step.satellites.map(\.id), [Fix.loft.id])
        XCTAssertEqual(step.satellites.first?.selected, true, "the walk's pick is drawn")
        XCTAssertEqual(step.found.map(\.id), [desk.id])
        XCTAssertEqual(step.found.first?.pairTitle, "Pair…")
        XCTAssertEqual(step.moonlight.map(\.id), [Fix.host.id])
        XCTAssertEqual(step.scan, ScanControlState(title: "Rescan", enabled: true, showsBar: false))
        XCTAssertNil(step.empty)
        XCTAssertNil(step.priming)
        XCTAssertEqual(step.footnote, "Pairing is one-time. After this, Dish reconnects to it by itself.")
    }

    func testDestinationSaysWhileItScans() throws {
        let state = page(walked(to: .destination)) { $0.connections.scanning = true }
        guard case let .destination(step) = try content(state) else { return XCTFail("destination") }
        XCTAssertEqual(step.heading.subtitle, "Scanning your Wi-Fi for a Satellite host.")
        XCTAssertEqual(step.scan, ScanControlState(title: "Scanning…", enabled: false, showsBar: true))
    }

    func testDestinationWithNothingToPickOffersSatelliteAndARescan() throws {
        guard case let .destination(step) = try content(page(walked(to: .destination), connections: [])) else {
            return XCTFail("destination")
        }
        let empty = try XCTUnwrap(step.empty)
        XCTAssertEqual(empty.card.title, "No PCs found yet")
        XCTAssertEqual(empty.getApp, "Get Satellite ↗")
        XCTAssertEqual(empty.secondary, "Rescan")
        XCTAssertNil(empty.settings)
        XCTAssertEqual(step.footnote, "Don’t see your PC? Install the free Satellite app on it.")
    }

    func testDestinationExplainsThePromptBeforeTheFirstScanEver() throws {
        guard case let .destination(step) = try content(page(walked(to: .destination), connections: [], primed: false)) else {
            return XCTFail("destination")
        }
        XCTAssertEqual(step.priming?.action, "Show me the prompt")
        XCTAssertNil(step.empty, "nothing was looked for yet")
    }

    func testARefusedNetworkOffersSystemSettingsInTheWalk() throws {
        let state = page(walked(to: .destination), connections: []) { $0.connections.localNetworkDenied = true }
        guard case let .destination(step) = try content(state) else { return XCTFail("destination") }
        XCTAssertEqual(step.empty?.card.hint, L10n.app.localNetworkDenied)
        XCTAssertEqual(step.empty?.settings?.title, "Open System Settings")
    }

    // MARK: - Type, Session, Feel

    func testTypeAsksHowThePcSeesASatellitesPad() throws {
        guard case let .type(step) = try content(page(walked(to: .type))) else { return XCTFail("type") }
        XCTAssertEqual(step.heading.title, "How should the PC see it?")
        XCTAssertNil(step.emulate, "no catalog read for the candidate yet")
        XCTAssertEqual(step.waiting, "Waiting on the type…")
    }

    func testTypeAsksHowTheMoonlightHostSeesItByName() throws {
        let state = page(walked(to: .type, host: Fix.host.id, kind: .moonlight))
        guard case let .type(step) = try content(state) else { return XCTFail("type") }
        XCTAssertEqual(step.heading.title, "How should the host see it?")
        XCTAssertEqual(step.heading.subtitle, "Dish asks PC to plug in this controller. Some hosts override the choice.")
    }

    func testSessionOffersTheHostsAppsOrSaysWhatRunsWithoutAPick() throws {
        let session = walked(to: .session, host: Fix.host.id, kind: .moonlight)
        guard case let .session(bare) = try content(page(session)) else { return XCTFail("session") }
        XCTAssertEqual(bare.heading, SetupHeading(title: "Session", subtitle: "Without a pick, Dish starts whatever PC lists first."))
        XCTAssertNil(bare.picker)
        let desktop = MoonlightApp(id: "1", title: "Desktop", hdrSupported: false)
        let listed = page(session) { $0.connections.moonlight.apps[Fix.host.id] = [desktop] }
        guard case let .session(step) = try content(listed) else { return XCTFail("session") }
        XCTAssertEqual(step.hostId, Fix.host.id)
        XCTAssertEqual(step.picker?.options.map(\.title), ["Auto", "Desktop"])
    }

    func testFeelOffersThePadsOwnSwitches() throws {
        guard case let .feel(step) = try content(page(walked(to: .feel))) else { return XCTFail("feel") }
        XCTAssertEqual(step.heading.title, "How should it feel?")
        XCTAssertEqual(step.functions.switches.map(\.key), [.motion, .rumble])
        XCTAssertNotNil(step.functions.touchpad)
        XCTAssertEqual(step.footnote, "Nothing here is saved yet. Everything travels with the bind on the next step.")
    }

    // MARK: - Review

    func testReviewDrawsTheBindingAndSaysNothingWasSentYet() throws {
        guard case let .review(step) = try content(page(walked(to: .review))) else { return XCTFail("review") }
        XCTAssertEqual(step.heading.title, "Review and bind")
        XCTAssertEqual(step.lines.map(\.label), ["Input", "Destination", "Type"])
        XCTAssertEqual(step.lines.map(\.value).prefix(2), ["DualSense", "Loft"])
        XCTAssertEqual(step.footnote, "Nothing on Loft has changed yet. Bind is the first and only write.")
        XCTAssertFalse(step.carries.rows.isEmpty)
    }

    // MARK: - The blockers

    func testALostHostSaysWhichAndOffersStartOverAndExit() throws {
        let lost = reduceSetup(reduceSetup(walked(to: .feel), .hostLive(true)).state, .hostLive(false)).state
        let blocker = try XCTUnwrap(page(lost).walk?.blocker)
        let expected = BlockerCardState(
            title: "Connection lost",
            message: "Loft stopped responding. Input isn’t getting through. It may be asleep or off your network.",
            tone: DishTheme.error,
            startOver: "Start over",
            exit: "Exit"
        )
        XCTAssertEqual(blocker, expected)
        XCTAssertFalse(page(lost).walk?.footer.primaryEnabled ?? true, "a blocked walk does not go on")
    }

    func testAnUnpluggedPadHoldsTheBindingInTheWarningTone() throws {
        let gone = reduceSetup(walked(to: .feel), .padPresent(false)).state
        let blocker = try XCTUnwrap(page(gone).walk?.blocker)
        XCTAssertEqual(blocker.title, "Controller unplugged")
        XCTAssertEqual(blocker.message, "Holding the binding so you can reconnect. Re-plug to keep configuring, or close this screen.")
        XCTAssertEqual(blocker.tone, DishTheme.warning)
    }
}
