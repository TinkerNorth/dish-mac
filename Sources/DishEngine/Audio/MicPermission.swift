// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AVFoundation
import DishKernel
import Foundation

/// Whether the system lets this app capture a microphone, re-read on every
/// start and asked for when a controller's mic switch is first turned on,
/// as dish-android asks. A `StateSource<Bool>` so the engine refolds when
/// the answer changes.
@MainActor
package final class MicPermissionGate: StateSource<Bool> {

    private let read: () -> Bool
    private let ask: (@escaping @Sendable (Bool) -> Void) -> Void

    /// The system's own answer by default; tests inject theirs.
    package init(read: @escaping () -> Bool = systemStatus, ask: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = systemRequest) {
        self.read = read
        self.ask = ask
        super.init(initial: read())
    }

    private nonisolated static func systemStatus() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private nonisolated static func systemRequest(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    package func refresh() {
        setState(read())
    }

    /// Asks once; the answer lands on the main actor.
    package func request() {
        ask { [weak self] granted in
            Task { @MainActor [weak self] in self?.setState(granted) }
        }
    }
}
