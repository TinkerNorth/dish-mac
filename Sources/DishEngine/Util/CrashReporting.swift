// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import Foundation

/// The seam the Share crash reports switch flips. The engine never sees the
/// SDK: the app hands it an uploader, and a build that carries no reporting
/// address hands one that stays inert whatever the switch says.
package protocol CrashUploader: AnyObject {
    /// Whether this build could send anything at all, for the words beside
    /// the switch: a switch that cannot do anything should say so.
    var canUpload: Bool { get }
    func setEnabled(_ enabled: Bool)
}

/// The Share crash reports switch and the uploader it drives, as on the
/// other clients: on by default under the fleet's key, persisted, and the
/// stored value handed to the uploader before anything could be sent. The
/// local crash log is not behind it.
@MainActor
package final class CrashReportingController: StateSource<Bool> {
    private let defaults: UserDefaults
    private let uploader: CrashUploader?

    package init(defaults: UserDefaults = .standard, uploader: CrashUploader? = nil) {
        self.defaults = defaults
        self.uploader = uploader
        let stored = defaults.object(forKey: CrashUploadPolicy.enabledKey) as? Bool
        let enabled = stored ?? CrashUploadPolicy.defaultEnabled
        uploader?.setEnabled(enabled)
        super.init(initial: enabled)
    }

    /// Whether this build could send a report at all, for the words beside
    /// the switch.
    package var uploadPossible: Bool {
        uploader?.canUpload ?? false
    }

    package func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: CrashUploadPolicy.enabledKey)
        uploader?.setEnabled(enabled)
        setState(enabled)
    }
}
