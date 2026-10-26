// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The one window: the rail as the split view's sidebar, and the content
/// column with the shell header over a navigation stack whose root is the
/// rail's destination. The shell owns the one toast host, above every page,
/// and registers no sheet: pairing and the Moonlight PIN are inline cards.
/// On a first run the welcome covers it all, full-window, until it is left.
struct ShellView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    /// The bundled third-party notice, read once at launch.
    let licenseNotice: String?

    private let words = L10n.app

    private var state: ShellState {
        shellState(navigation.state, ShellInputs(facts: model.shellFacts, connections: model.connections, mic: model.micIndicator))
    }

    private var railWidth: CGFloat {
        navigation.state.railCollapsed ? DishSize.railCompact : DishSize.railExpanded
    }

    var body: some View {
        ZStack {
            shell
            if navigation.state.showingWelcome {
                WelcomeView()
            }
        }
    }

    private var shell: some View {
        NavigationSplitView(columnVisibility: navigation.columnVisibility) {
            RailView(state: state, select: select, setUp: openSetup)
                .navigationSplitViewColumnWidth(min: railWidth, ideal: railWidth, max: railWidth)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                ShellHeader(state: state, backLabel: words.back, actions: headerActions)
                NavigationStack(path: navigation.path) {
                    root
                        .shellPage()
                        .navigationDestination(for: Page.self, destination: pushed)
                }
            }
            .background(DishTheme.background)
        }
        .overlay(alignment: .bottom) {
            NotificationOverlay()
        }
        .onChange(of: model.pairingTarget?.id, perform: showPairing)
        .onChange(of: model.moonlightPin?.id, perform: showMoonlightPin)
    }

    private var headerActions: ShellHeader.Actions {
        ShellHeader.Actions(back: back, configure: configure, toggleMic: model.toggleAllMics)
    }

    @ViewBuilder
    private var root: some View {
        switch navigation.state.destination {
        case .home: HomePage()
        case .controllers: ControllersPage()
        case .connections: ConnectionsPage()
        case .support: SupportPage()
        case .settings: SettingsPage()
        }
    }

    @ViewBuilder
    private func pushed(_ page: Page) -> some View {
        switch page {
        case .diagnostics: DiagnosticsPage().shellPage()
        case let .inspector(slotId): InspectorPage(slotId: slotId).shellPage()
        case .crashReport: CrashReportPage().shellPage()
        case .licenses: LicensesPage(state: licensesState).shellPage()
        case .moonlightHosts: MoonlightHostsPage().shellPage()
        case let .configureBinding(slotId): ConfigureBindingPage(slotId: slotId).shellPage()
        case let .deadZones(slotId): DeadZonesPage(slotId: slotId).shellPage()
        case let .setup(seedSlotId): SetupPage(seedSlotId: seedSlotId).shellPage()
        case .help: HelpPage().shellPage()
        }
    }

    private var licensesState: LicensesPageState {
        licensesPageState(notice: licenseNotice, appVersion: model.shellFacts.update.currentVersion)
    }

    private func select(_ destination: Destination) {
        navigation.send(.select(destination))
    }

    private func back() {
        navigation.send(.pop)
    }

    /// The rail's Set up: Home first, then the walk.
    private func openSetup() {
        navigation.send(.openSetup(seedSlotId: nil))
    }

    private func configure() {
        navigation.send(.select(.settings))
    }

    /// A pairing card lives on its row on the Connections page, or in the
    /// setup walk's Destination step, so a satellite that asks to pair brings
    /// the page up unless the walk draws the card itself.
    private func showPairing(_ serverId: String?) {
        if serverId != nil { navigation.send(.pairingCardOpened) }
    }

    /// The Moonlight PIN lives on its host's row, so a host that minted one
    /// brings the Moonlight hosts page up.
    private func showMoonlightPin(_ hostId: String?) {
        if hostId != nil { navigation.send(.external(.showPage(.moonlightHosts))) }
    }
}

private extension View {
    /// A page fills the content column under the shell header, which draws
    /// its own back chevron.
    func shellPage() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DishTheme.background)
            .navigationBarBackButtonHidden(true)
    }
}
