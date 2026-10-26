// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The flight recorder behind the Diagnostics window: consecutive snapshots
// of the satellite links and the controller slots, turned into what changed
// between them, so "it dropped some time last night" arrives as a
// timestamped sequence. Onsets only: the first snapshot doubles as the
// session's opening inventory. Pure functions over the shapes the UI already
// renders; the recorder feeds them and the store keeps the lines.

import Foundation

package struct LinkSnapshot: Equatable {
    package let id: String
    package let label: String
    package let state: LinkState

    package init(id: String, label: String, state: LinkState) {
        self.id = id
        self.label = label
        self.state = state
    }
}

package struct PadSnapshot: Equatable {
    package let id: String
    package let name: String
    /// The host the pad is bound to: the id says whether it moved, the
    /// label is what the log shows. Both empty while it is unbound.
    package let boundId: String
    package let boundLabel: String

    package init(id: String, name: String, boundId: String, boundLabel: String) {
        self.id = id
        self.name = name
        self.boundId = boundId
        self.boundLabel = boundLabel
    }
}

package enum DiagnosticsEventKind: Equatable {
    case linkAppeared
    case linkChanged
    case linkRemoved
    case padAttached
    case padDetached
    case padBound
    case padUnbound
}

/// One line of the log. `from` and `to` mean something for a link (one that
/// appears has only a `to`), `host` for a bind or an unbind. `sequence` is
/// the store's running number, so two lines in one tick stay distinct.
package struct DiagnosticsEvent: Equatable, Identifiable {
    package var sequence = 0
    package let atMs: Int64
    package let kind: DiagnosticsEventKind
    package let subject: String
    package var from: LinkState = .saved
    package var to: LinkState = .saved
    package var host = ""

    package var id: Int {
        sequence
    }

    package init(
        sequence: Int = 0, atMs: Int64, kind: DiagnosticsEventKind, subject: String,
        from: LinkState = .saved, to: LinkState = .saved, host: String = ""
    ) {
        self.sequence = sequence
        self.atMs = atMs
        self.kind = kind
        self.subject = subject
        self.from = from
        self.to = to
        self.host = host
    }
}

package enum DiagnosticsLog {
    /// About a day of an ordinary session's churn, and small enough to copy
    /// whole into a bug report.
    package static let capacity = 200
}

package extension ConnectionSummary {
    /// What the flight recorder writes and the rows are ordered by: the
    /// advertised name, else the address, which a bug report can still match.
    var recordName: String {
        name.isEmpty ? address : name
    }
}

package func linkSnapshot(of summary: ConnectionSummary) -> LinkSnapshot {
    LinkSnapshot(id: summary.id, label: summary.recordName, state: summary.live)
}

/// The host's label, or its id once the row has gone, which is still better
/// than a blank in a bug report.
package func padSnapshot(of slot: ControllerSlot) -> PadSnapshot {
    PadSnapshot(
        id: slot.id,
        name: slot.name,
        boundId: slot.boundConnectionId ?? "",
        boundLabel: slot.boundStatus?.recordName ?? slot.boundConnectionId ?? ""
    )
}

package func linkEvents(before: [LinkSnapshot], after: [LinkSnapshot], atMs: Int64) -> [DiagnosticsEvent] {
    let appearedOrChanged = after.flatMap { link -> [DiagnosticsEvent] in
        guard let previous = before.first(where: { $0.id == link.id }) else {
            return [DiagnosticsEvent(atMs: atMs, kind: .linkAppeared, subject: link.label, to: link.state)]
        }
        guard previous.state != link.state else { return [] }
        return [DiagnosticsEvent(atMs: atMs, kind: .linkChanged, subject: link.label, from: previous.state, to: link.state)]
    }
    let removed = before
        .filter { link in !after.contains { $0.id == link.id } }
        .map { DiagnosticsEvent(atMs: atMs, kind: .linkRemoved, subject: $0.label, to: $0.state) }
    return appearedOrChanged + removed
}

/// A move to another host is a bind to the new one; only losing the host
/// altogether is an unbind, which names the host the pad left.
package func padEvents(before: [PadSnapshot], after: [PadSnapshot], atMs: Int64) -> [DiagnosticsEvent] {
    let attachedOrRebound = after.flatMap { pad -> [DiagnosticsEvent] in
        guard let previous = before.first(where: { $0.id == pad.id }) else {
            return [DiagnosticsEvent(atMs: atMs, kind: .padAttached, subject: pad.name)]
        }
        return bindingChange(from: previous, to: pad, atMs: atMs)
    }
    let detached = before
        .filter { pad in !after.contains { $0.id == pad.id } }
        .map { DiagnosticsEvent(atMs: atMs, kind: .padDetached, subject: $0.name, host: $0.boundLabel) }
    return attachedOrRebound + detached
}

private func bindingChange(from previous: PadSnapshot, to pad: PadSnapshot, atMs: Int64) -> [DiagnosticsEvent] {
    guard previous.boundId != pad.boundId else { return [] }
    if pad.boundId.isEmpty {
        return [DiagnosticsEvent(atMs: atMs, kind: .padUnbound, subject: previous.name, host: previous.boundLabel)]
    }
    return [DiagnosticsEvent(atMs: atMs, kind: .padBound, subject: pad.name, host: pad.boundLabel)]
}

/// The log with `events` appended and numbered on from `nextSequence`,
/// keeping only the newest `capacity`.
package func appendBounded(
    _ log: [DiagnosticsEvent],
    _ events: [DiagnosticsEvent],
    capacity: Int,
    nextSequence: Int
) -> [DiagnosticsEvent] {
    let numbered = events.enumerated().map { offset, event in
        var stamped = event
        stamped.sequence = nextSequence + offset
        return stamped
    }
    return Array((log + numbered).suffix(capacity))
}
