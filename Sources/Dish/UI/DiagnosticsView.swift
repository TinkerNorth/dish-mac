// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import DishEngine
import SwiftUI

/// Diagnostics: what the app sees right now. Each satellite session's own
/// account of itself, each controller down to the wire, and the flight
/// recorder. Read-only: every figure is one the rest of the app already acts
/// on, not a second measurement. The source ticks while the window is open.
struct DiagnosticsView: View {

    @EnvironmentObject var diagnostics: DiagnosticsSource
    @EnvironmentObject var log: DiagnosticsLogStore
    @State private var copied = false

    private let words = L10n.app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(words.diagnosticsDetail)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                hostsSection
                controllersSection
                eventsSection
            }
            .padding(16)
        }
        .background(DishTheme.background.ignoresSafeArea())
        .onAppear { diagnostics.start() }
        .onDisappear { diagnostics.stop() }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.hosts)
            if diagnostics.state.hosts.isEmpty {
                emptyNote(words.noSatellitesYet)
            }
            ForEach(diagnostics.state.hosts) { host in
                DiagnosticsCard(
                    title: host.summary.label,
                    dot: linkDotColor(host.summary.live),
                    chip: linkStateText(host.summary.live),
                    lines: hostLines(host)
                )
            }
        }
    }

    private var controllersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.controllers)
            if diagnostics.state.pads.isEmpty {
                emptyNote(words.noControllersConnected)
            }
            ForEach(diagnostics.state.pads) { pad in
                DiagnosticsCard(title: pad.slot.name, dot: nil, chip: nil, lines: padLines(pad))
            }
        }
    }

    /// The newest lines, newest first; Copy takes all of them, oldest first.
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SectionHeader(title: words.events)
                Spacer()
                if copied {
                    Text(words.eventsCopied)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.success)
                }
                Button(words.copy, action: copyEvents)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(log.state.isEmpty)
            }
            ForEach(recentEvents(log.state)) { event in
                Text(eventLine(event))
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.onSurface)
                    .textSelection(.enabled)
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(DishFont.detail)
            .foregroundColor(DishTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copyEvents() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(eventsTranscript(log.state), forType: .string)
        copied = true
    }
}

/// One card: a headline with its dot and chip, then one fact per line with
/// the key in a fixed left column so every card lines up.
private struct DiagnosticsCard: View {

    let title: String
    let dot: Color?
    let chip: String?
    let lines: [FactLine]

    private static let keyColumn: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let dot {
                    StatusDot(color: dot)
                }
                Text(title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                if let chip {
                    Text(chip)
                        .font(DishFont.monoChip)
                        .foregroundColor(DishTheme.muted)
                }
            }
            ForEach(lines) { line in
                factLine(line)
            }
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func factLine(_ line: FactLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.key)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .frame(width: Self.keyColumn, alignment: .leading)
            Text(line.value)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
