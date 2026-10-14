// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Sentry SDK behind the Share crash reports switch. Two separate things
// happen when Dish crashes, and only one of them is behind the switch: the
// engine's own handler always appends a backtrace to the local crash log,
// which the user reviews, redacted, and sends only by hand; this uploader,
// when armed, sends one report per crash to Sentry. The SDK keeps the
// handlers it found and hands the crash on to them, so the local log is
// written either way, and closing the SDK puts them back as they were.
//
// A build arms only with an address compiled into its Info.plist, which
// `bundle.sh` writes from a release-time secret: a `swift run`, a pull
// request or a fork carries none and this stays inert whatever the switch
// says. The crash is the only event: no sessions, no breadcrumbs, no
// network tracing, and the report names no user and no host.

import DishCore
import DishEngine
import Foundation
import Sentry

public final class SentryCrashUploader: CrashUploader {
    private let dsn: String?
    private let release: String
    public private(set) var active = false

    public init(dsn: String?, appVersion: String) {
        self.dsn = dsn
        release = CrashUploadPolicy.release(version: appVersion)
    }

    public var canUpload: Bool {
        CrashUploadPolicy.carriesAddress(dsn)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else {
            disarm()
            return
        }
        guard !active, CrashUploadPolicy.shouldArm(dsn: dsn, userEnabled: true), let dsn else { return }
        let release = release
        SentrySDK.start { options in
            configure(options, dsn: dsn, release: release)
        }
        active = true
    }

    /// Closing the SDK restores the handlers it found, so the next crash
    /// writes the local log alone and sends nothing.
    private func disarm() {
        guard active else { return }
        active = false
        SentrySDK.close()
    }
}

/// The crash and nothing else: every automatic collection the SDK offers
/// is turned off, and what it would attach of the machine is stripped.
func configure(_ options: Options, dsn: String, release: String) {
    options.dsn = dsn
    options.releaseName = release
    options.environment = CrashUploadPolicy.environment(dsn: dsn)
    options.sendDefaultPii = false
    options.enableAutoSessionTracking = false
    options.enableAutoBreadcrumbTracking = false
    options.enableSwizzling = false
    options.enableNetworkTracking = false
    options.maxBreadcrumbs = 0
    options.beforeSend = scrub
}

/// The report names no user, no host and no trail of what was done before.
func scrub(_ event: Event) -> Event? {
    event.user = nil
    event.serverName = nil
    event.breadcrumbs = nil
    return event
}
