// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import Foundation

package typealias ReportPreparationState = AsyncState<ReportPreparation, Never>

/// Preparing a support report: every live satellite asked for its own view
/// of the connection, and the Mac's conditions read off the main actor. A
/// second `prepare` while one runs replaces it; nothing here is sent
/// anywhere but to the person's own hosts.
@MainActor
package final class ReportPreparationSource: StateSource<ReportPreparationState> {

    private let snapshots: @MainActor () async -> [String: HostSnapshotVerdict]
    private let conditions: DeviceConditionsReading
    private var task: Task<Void, Never>?

    init(snapshots: @escaping @MainActor () async -> [String: HostSnapshotVerdict], conditions: DeviceConditionsReading) {
        self.snapshots = snapshots
        self.conditions = conditions
        super.init(initial: .idle)
    }

    package func prepare() {
        task?.cancel()
        setState(state.toLoading())
        task = Task { [weak self] in await self?.gather() }
    }

    /// Waits for the preparation in flight, for a caller that needs it whole.
    package func settled() async {
        await task?.value
    }

    private func gather() async {
        let reading = conditions
        async let read = Task.detached(priority: .userInitiated) { reading.read() }.value
        let verdicts = await snapshots()
        let preparation = await ReportPreparation(snapshots: verdicts, conditions: read)
        guard !Task.isCancelled else { return }
        setState(state.toSuccess(preparation))
    }
}
