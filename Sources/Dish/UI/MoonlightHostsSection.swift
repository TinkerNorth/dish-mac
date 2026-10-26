// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// The Moonlight half of the Connections page: the hosts the records or a
/// scan know, each with its trust, its session's standing, the controllers
/// it carries, the app it starts, and the way out of where it stands; and
/// an address field for a host that advertises nothing.
struct MoonlightHostsSection: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var moonlight: MoonlightConnectionManager
    @State private var address = ""
    @State private var addressError: String?

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            let rows = moonlightRows(known: model.connections, discovered: moonlight.discoveredHosts)
            if rows.isEmpty {
                Text(words.noMoonlightHostsHint)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows, id: \.key) { row in
                    rowView(row)
                }
            }
            addRow
            if let addressError {
                ErrorBanner(message: addressError) { self.addressError = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(DishFont.icon)
                .foregroundColor(DishTheme.muted)
            SectionHeader(title: words.moonlightHostsSection)
            if moonlight.isScanning {
                DishSpinner(size: 11)
            }
            Spacer()
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField(words.moonlightAddressPlaceholder, text: $address)
                .textFieldStyle(.roundedBorder)
                .font(DishFont.detail)
                .onSubmit { submitAddress() }
            Button(words.add) { submitAddress() }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    private func submitAddress() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addressError = words.enterTheHostAddress
            return
        }
        model.addMoonlightHost(trimmed)
        address = ""
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: MoonlightRow) -> some View {
        switch row {
        case let .known(summary): knownRow(summary)
        case let .discovered(host): discoveredRow(host)
        }
    }

    private func knownRow(_ summary: ConnectionSummary) -> some View {
        let phase = moonlight.phase(of: summary.id)
        return HStack(spacing: 10) {
            hostGlyph(dot: linkDotColor(summary.live))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(summary.detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                Text(statusLine(for: summary))
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
                if let line = moonlightStatusLine(summary, phase: phase) {
                    Text(line)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                }
                trustLine(summary)
                appPicker(summary)
            }
            Spacer()
            actionButtons(summary, phase: phase)
            Button(words.forget) { model.forget(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
                .help(words.forgetMoonlightHelp(summary.label))
        }
        .moonlightRowBackground()
    }

    /// The trust word, how many controllers ride the host, and the link's tier.
    private func trustLine(_ summary: ConnectionSummary) -> some View {
        HStack(spacing: 8) {
            Text(moonlightTrustText(summary))
                .font(DishFont.monoChip)
                .foregroundColor(moonlightTrustColor(summary))
            if let count = moonlightControllersText(summary) {
                Text(count)
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
            }
            Text(linkTierText(summary.kind))
                .font(DishFont.monoChip)
                .foregroundColor(linkTierColor(summary.kind))
                .help(linkTierHelp(summary.kind))
        }
    }

    /// The app the host's session starts, once a probe has listed them: the
    /// first listed by default, or the pick, shared by every pad on the host.
    @ViewBuilder
    private func appPicker(_ summary: ConnectionSummary) -> some View {
        if let apps = moonlight.hostApps[summary.id], !apps.isEmpty {
            HStack(spacing: 8) {
                Text(words.app)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                Picker("", selection: appBinding(summary.id, apps: apps)) {
                    Text(words.auto).tag("")
                    ForEach(apps, id: \.id) { app in
                        Text(app.title.isEmpty ? app.id : app.title).tag(app.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                if moonlight.rememberedAppId(hostId: summary.id).isEmpty {
                    Text(words.withoutAPick(summary.label))
                        .font(DishFont.microRegular)
                        .foregroundColor(DishTheme.muted)
                }
            }
        }
    }

    private func appBinding(_ hostId: String, apps: [MoonlightApp]) -> Binding<String> {
        Binding(
            get: { moonlight.rememberedAppId(hostId: hostId) },
            set: { picked in
                let title = apps.first { $0.id == picked }?.title ?? ""
                model.setMoonlightApp(hostId, appId: picked, appName: title)
            }
        )
    }

    private func actionButtons(_ summary: ConnectionSummary, phase: MoonlightSessionPhase?) -> some View {
        let pairing = moonlight.pairingInFlight.contains(summary.id)
        return ForEach(moonlightRowActions(summary, phase: phase), id: \.self) { action in
            Button(moonlightActionText(action, host: summary.label)) { perform(action, on: summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(pairing)
        }
    }

    private func perform(_ action: MoonlightRowAction, on hostId: String) {
        switch action {
        case .pair, .rePair: model.pairMoonlight(hostId)
        case .disconnect: model.disconnect(hostId)
        case .reconnect, .startSession, .retry: model.retryMoonlightSessions()
        case .quitApp: model.quitMoonlightApp(hostId)
        }
    }

    private func discoveredRow(_ host: MoonlightHost) -> some View {
        let pairing = moonlight.pairingInFlight.contains(host.id)
        return HStack(spacing: 10) {
            hostGlyph(dot: DishTheme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(moonlightHostTitle(host))
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(moonlightHostDetail(host))
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                Text(moonlightDiscoveredStatusText())
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Button(pairing ? words.pairing : words.pairNow) { model.pairMoonlight(host.id) }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(pairing)
        }
        .moonlightRowBackground()
    }

    private func hostGlyph(dot: Color) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "desktopcomputer")
                .font(DishFont.title)
                .foregroundColor(DishTheme.muted)
                .frame(width: 28, height: 28)
            StatusDot(color: dot)
        }
    }
}

private extension View {
    func moonlightRowBackground() -> some View {
        self
            .padding(12)
            .background(DishTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
