// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// The host's sleep and wake, as the desktops handle suspend and resume:
/// sleep releases every held input and closes every session cleanly, wake
/// reopens them and scans again, since a laptop may wake on another network.
package extension AppModel {
    /// Fires once on the wake after the lid closed on a stream, for the app to word.
    var lidPausedStreaming: AnyPublisher<Void, Never> {
        lidWatch.lidPausedStreaming.eraseToAnyPublisher()
    }

    internal func installLifecycleHandling(_ lifecycle: LifecycleSignals) {
        lifecycle.willSleep
            .sink { [weak self] in self?.prepareForSleep() }
            .store(in: &cancellables)
        lifecycle.didWake
            .sink { [weak self] in self?.resumeAfterWake() }
            .store(in: &cancellables)
    }

    /// The lid and the stream are read before anything closes; the released
    /// reports leave on the sessions before they go.
    internal func prepareForSleep() {
        let streaming = streamingCount.state > 0
        lidWatch.noteSleep(streaming: streaming)
        input.processor.zeroAndSendAll()
        wifi.closeSessionsForSleep()
        moonlight.stopSessionsForSleep()
    }

    internal func resumeAfterWake() {
        wifi.resumeAfterWake()
        moonlight.retrySessions()
        wifi.startDiscovery(trigger: .wake)
        moonlight.startDiscovery()
        lidWatch.noteWake()
    }
}
