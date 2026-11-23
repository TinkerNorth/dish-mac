// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import SwiftUI

/// The person's own mail app, and a save panel when there is none, as a
/// value the scene hands its pages: Continue in Mail calls an action
/// instead of reaching for AppKit itself. Nothing is sent until the person
/// presses Send in their mail app. Outside the scene it does nothing.
struct DiagnosticsMailer {
    /// False when no mail service can take the message.
    let compose: @MainActor @Sendable (DiagnosticsMailState, URL) -> Bool
    /// The file copied where the person picks; nil when they closed the panel.
    let save: @MainActor @Sendable (URL) -> URL?

    static let system = DiagnosticsMailer(compose: { composeEmail($0, attaching: $1) }, save: { saveWithPanel($0) })
    static let inert = DiagnosticsMailer(compose: { refuseCompose($0, $1) }, save: { ignoreSave($0) })
}

/// `NSSharingService(named: .composeEmail)`: the recipient, the subject, the
/// body and the file.
@MainActor
private func composeEmail(_ mail: DiagnosticsMailState, attaching file: URL) -> Bool {
    guard let service = NSSharingService(named: .composeEmail) else { return false }
    let items: [Any] = [mail.body, file]
    guard service.canPerform(withItems: items) else { return false }
    service.recipients = [mail.recipient]
    service.subject = mail.subject
    service.perform(withItems: items)
    return true
}

@MainActor
private func saveWithPanel(_ file: URL) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = file.lastPathComponent
    guard panel.runModal() == .OK, let target = panel.url else { return nil }
    do {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: file, to: target)
        return target
    } catch {
        return nil
    }
}

@MainActor
private func refuseCompose(_: DiagnosticsMailState, _: URL) -> Bool {
    false
}

@MainActor
private func ignoreSave(_: URL) -> URL? {
    nil
}

private struct DiagnosticsMailerKey: EnvironmentKey {
    static let defaultValue = DiagnosticsMailer.inert
}

extension EnvironmentValues {
    var diagnosticsMailer: DiagnosticsMailer {
        get { self[DiagnosticsMailerKey.self] }
        set { self[DiagnosticsMailerKey.self] = newValue }
    }
}
