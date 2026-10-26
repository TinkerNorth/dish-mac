// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// Configure binding, pushed from a Home row or a Controllers card: Input ·
/// Destination · Functions · Emulate as on the left, What carries on the
/// right, and the Unbind / Cancel / Apply bar pinned below. Every answer
/// lands in the draft; Apply is the one write, shown by the in-page
/// "Applying binding…" overlay. A dirty draft asks before the page is left.
struct ConfigureBindingPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    let slotId: String

    private var state: ConfigureBindingPageState {
        configureBindingPageState(BindingInputs(
            slotId: slotId,
            slots: model.slots,
            connections: model.connections,
            facts: model.shellFacts
        ))
    }

    var body: some View {
        let state = state
        content(state.content)
            .overlay {
                if let overlay = state.overlay {
                    ApplyOverlay(state: overlay, cancel: model.cancelApply, close: closeOverlay)
                }
            }
            .confirmationDialog(state.leave.title, isPresented: leaveAsked, titleVisibility: .visible) {
                Button(state.leave.discard, role: .destructive, action: leave)
                Button(state.leave.keep, role: .cancel, action: stay)
            } message: {
                Text(state.leave.message)
            }
            .onChange(of: state.dirty, perform: armGuard)
            .onAppear { model.pageAppeared(.configureBinding(slotId: slotId)) }
            .onDisappear { model.pageDisappeared(.configureBinding(slotId: slotId)) }
    }

    @ViewBuilder
    private func content(_ content: BindingContent) -> some View {
        switch content {
        case .opening:
            Color.clear
        case let .missing(title, body):
            EmptyStateCard(title: title, message: body)
                .padding(DishSpace.page)
                .frame(maxHeight: .infinity, alignment: .top)
        case let .editing(editor):
            VStack(spacing: 0) {
                ScrollView {
                    BindingSections(state: editor, actions: sectionActions)
                        .padding(DishSpace.page)
                }
                Divider()
                BindingBar(state: editor.bar, actions: barActions(editor.draft))
            }
        }
    }

    private var sectionActions: BindingSections.Actions {
        BindingSections.Actions(edit: model.editBinding, manageDestinations: manageDestinations)
    }

    private func barActions(_ draft: BindingDraft) -> BindingBar.Actions {
        BindingBar.Actions(unbind: model.unbindFromDraft, cancel: cancel, apply: { model.applyBinding(draft) })
    }

    /// The guard's question is up while a move it holds waits for an answer.
    private var leaveAsked: Binding<Bool> {
        Binding(get: { navigation.state.pendingLeaveGuard != nil }, set: dismissedQuestion)
    }

    private func dismissedQuestion(_ shown: Bool) {
        if !shown, navigation.state.pendingLeaveGuard != nil { stay() }
    }

    private func armGuard(_ dirty: Bool) {
        navigation.send(.guardLeave(dirty))
    }

    private func leave() {
        navigation.send(.leaveGuard(.leave))
    }

    private func stay() {
        navigation.send(.leaveGuard(.stay))
    }

    private func cancel() {
        navigation.send(.pop)
    }

    private func manageDestinations() {
        navigation.send(.select(.connections))
    }

    /// Done pops back to where the page was opened from; a failure stays,
    /// the draft intact for another try.
    private func closeOverlay() {
        let landed = state.popsOnClose
        model.dismissApply()
        if landed { navigation.send(.pop) }
    }
}
