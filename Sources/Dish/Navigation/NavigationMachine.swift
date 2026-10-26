// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A rail destination: the root of the content column.
enum Destination: CaseIterable, Hashable {
    case home
    case controllers
    case connections
    case support
    case settings
}

/// A page pushed onto a destination's stack.
enum Page: Hashable {
    case diagnostics
    case inspector(slotId: String)
    case crashReport
    case licenses
    case moonlightHosts
}

/// Where a page lives when something outside the window asks for it.
func homeDestination(of page: Page) -> Destination {
    switch page {
    case .diagnostics, .inspector, .crashReport, .licenses: .settings
    case .moonlightHosts: .connections
    }
}

/// A navigation that replaces or unwinds the stack: the moves a page's leave
/// guard gets first refusal of.
enum NavigationMove: Equatable {
    case select(Destination)
    case pop
    case popToRoot
    case external(ExternalRequest)
}

/// What the menu-bar item asks of the window.
enum ExternalRequest: Equatable {
    case showDestination(Destination)
    case showPage(Page)
}

enum LeaveAnswer: Equatable {
    case stay
    case leave
}

enum NavigationEvent: Equatable {
    case select(Destination)
    case push(Page)
    case pop
    case popToRoot
    case toggleRail
    /// The page on screen arms or releases its leave guard.
    case guardLeave(Bool)
    /// The answer to the guard's question about the held move.
    case leaveGuard(LeaveAnswer)
    case external(ExternalRequest)
}

enum NavigationEffect: Equatable {
    case persistRail(collapsed: Bool)
    case activateWindow
}

struct NavigationState: Equatable {
    var destination = Destination.home
    var path: [Page] = []
    var railCollapsed = false
    /// The page on screen asks before the stack is replaced or unwound.
    var leaveGuarded = false
    /// The move the guard is holding until the page answers.
    var pendingLeaveGuard: NavigationMove?
    var showingWelcome = false
}

struct NavigationStep: Equatable {
    let state: NavigationState
    let effects: [NavigationEffect]
}

/// The shell's one navigation rule: a rail selection replaces the stack, a
/// page pushes onto it, and a guarded page gets first refusal of any move
/// that would take it off screen.
func reduceNavigation(_ state: NavigationState, _ event: NavigationEvent) -> NavigationStep {
    switch event {
    case let .select(destination): guarded(state, .select(destination))
    case let .push(page): pushed(state, page)
    case .pop: guarded(state, .pop)
    case .popToRoot: guarded(state, .popToRoot)
    case .toggleRail: toggledRail(state)
    case let .guardLeave(armed): guardChanged(state, armed: armed)
    case let .leaveGuard(answer): answered(state, answer)
    case let .external(request): guarded(state, .external(request))
    }
}

private func guarded(_ state: NavigationState, _ move: NavigationMove) -> NavigationStep {
    guard state.leaveGuarded else { return applied(state, move) }
    var held = state
    held.pendingLeaveGuard = move
    return NavigationStep(state: held, effects: activation(for: move))
}

/// The move itself, the guard released: the page that armed it is gone.
private func applied(_ state: NavigationState, _ move: NavigationMove) -> NavigationStep {
    var next = state
    next.leaveGuarded = false
    next.pendingLeaveGuard = nil
    switch move {
    case let .select(destination):
        next.destination = destination
        next.path = []
    case .pop:
        next.path = Array(state.path.dropLast())
    case .popToRoot:
        next.path = []
    case let .external(.showDestination(destination)):
        next.destination = destination
        next.path = []
    case let .external(.showPage(page)):
        next.destination = homeDestination(of: page)
        next.path = [page]
    }
    return NavigationStep(state: next, effects: activation(for: move))
}

/// A request from outside the window brings the window forward, even while
/// a guard holds it, so the guard's question is seen.
private func activation(for move: NavigationMove) -> [NavigationEffect] {
    switch move {
    case .external: [.activateWindow]
    case .select, .pop, .popToRoot: []
    }
}

private func pushed(_ state: NavigationState, _ page: Page) -> NavigationStep {
    var next = state
    next.path.append(page)
    next.leaveGuarded = false
    next.pendingLeaveGuard = nil
    return NavigationStep(state: next, effects: [])
}

private func toggledRail(_ state: NavigationState) -> NavigationStep {
    var next = state
    next.railCollapsed.toggle()
    return NavigationStep(state: next, effects: [.persistRail(collapsed: next.railCollapsed)])
}

private func guardChanged(_ state: NavigationState, armed: Bool) -> NavigationStep {
    var next = state
    next.leaveGuarded = armed
    if !armed { next.pendingLeaveGuard = nil }
    return NavigationStep(state: next, effects: [])
}

private func answered(_ state: NavigationState, _ answer: LeaveAnswer) -> NavigationStep {
    guard let move = state.pendingLeaveGuard else { return NavigationStep(state: state, effects: []) }
    switch answer {
    case .stay:
        var next = state
        next.pendingLeaveGuard = nil
        return NavigationStep(state: next, effects: [])
    case .leave:
        return applied(state, move)
    }
}
