// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// Set up Dish, the desktops' wizard as a page pushed onto Home: the stage
/// pips pinned above, one question at a time, the footer pinned below with
/// Back, Cancel, where the walk stands and its one way on. Nothing is sent
/// until Review's Bind, shown by the in-page "Applying binding…" overlay.
/// Past the first page, leaving asks first; a lost host or an unplugged pad
/// stops the walk in the page.
struct SetupPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    let seedSlotId: String?

    private var state: SetupPageState {
        setupPageState(SetupInputs(
            slots: model.slots,
            connections: model.connections,
            facts: model.shellFacts,
            openPairing: model.openPairing
        ))
    }

    var body: some View {
        let state = state
        content(state.walk)
            .confirmationDialog(state.leave.title, isPresented: leaveAsked, titleVisibility: .visible) {
                Button(state.leave.discard, role: .destructive, action: leave)
                Button(state.leave.keep, role: .cancel, action: stay)
            } message: {
                Text(state.leave.message)
            }
            .onChange(of: state.guarded, perform: armGuard)
            .onAppear { model.pageAppeared(.setup(seedSlotId: seedSlotId)) }
            .onDisappear { model.pageDisappeared(.setup(seedSlotId: seedSlotId)) }
    }

    @ViewBuilder
    private func content(_ walk: SetupWalkState?) -> some View {
        if let walk {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DishSpace.s4) {
                    StepPips(pips: walk.stages)
                    StepPips(pips: walk.subSteps)
                }
                .padding(.horizontal, DishSpace.page)
                .padding(.vertical, DishSpace.s6)
                Divider()
                ScrollView {
                    stepArea(walk)
                        .padding(DishSpace.page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                SetupFooter(state: walk.footer, actions: footerActions)
            }
            .overlay {
                if let overlay = walk.overlay {
                    ApplyOverlay(state: overlay, cancel: model.cancelApply, close: closeOverlay)
                }
            }
        } else {
            Color.clear
        }
    }

    /// A blocker stands in for the step until it is answered.
    @ViewBuilder
    private func stepArea(_ walk: SetupWalkState) -> some View {
        if let blocker = walk.blocker {
            BlockerCard(state: blocker, startOver: model.startSetupOver, exit: exit)
        } else {
            SetupStepView(content: walk.content)
        }
    }

    private var footerActions: SetupFooter.Actions {
        SetupFooter.Actions(back: model.setupBack, cancel: cancel, primary: model.setupNext)
    }

    /// The guard's question is up while a move it holds waits for an answer.
    private var leaveAsked: Binding<Bool> {
        Binding(get: { navigation.state.pendingLeaveGuard != nil }, set: dismissedQuestion)
    }

    private func dismissedQuestion(_ shown: Bool) {
        if !shown, navigation.state.pendingLeaveGuard != nil { stay() }
    }

    private func armGuard(_ guarded: Bool) {
        navigation.send(.guardLeave(guarded))
    }

    private func leave() {
        navigation.send(.leaveGuard(.leave))
    }

    private func stay() {
        navigation.send(.leaveGuard(.stay))
    }

    /// Cancel and Esc leave the way the rail does, through the guard.
    private func cancel() {
        navigation.send(.pop)
    }

    /// A blocker's Exit: the walk ends without asking, nothing was sent.
    private func exit() {
        navigation.send(.setupEnded(.exited))
    }

    /// Done ends the walk on Home; a failure stays, the answers intact.
    private func closeOverlay() {
        let landed = state.landed
        model.dismissApply()
        if landed { navigation.send(.setupEnded(.applied)) }
    }
}

/// The footer pinned under the walk: Back, Cancel, the position and its
/// advice, and the one primary.
struct SetupFooter: View {

    struct Actions {
        let back: () -> Void
        let cancel: () -> Void
        let primary: () -> Void
    }

    let state: SetupFooterState
    let actions: Actions

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            Button(state.back, action: actions.back)
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!state.backEnabled)
            Button(state.cancel, action: actions.cancel)
                .buttonStyle(DishOutlinedButtonStyle())
                .keyboardShortcut(.cancelAction)
            Text(state.hint)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .lineLimit(1)
            Spacer()
            Button(state.primary, action: actions.primary)
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!state.primaryEnabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DishSpace.page)
        .padding(.vertical, DishSpace.s6)
    }
}
