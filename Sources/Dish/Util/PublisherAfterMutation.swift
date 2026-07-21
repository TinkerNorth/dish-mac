// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

extension Publisher where Failure == Never {
    /// Deliver downstream one main-queue hop AFTER the mutation that
    /// triggered the emission settles.
    ///
    /// `@Published` and `objectWillChange` both fire in `willSet` — *before*
    /// the new value is readable — so a sink that re-reads the source object
    /// synchronously (`ConnectionHub.rebuild`, the `FeatureSettings` →
    /// `ForwardingGate` mirror) would observe the PRIOR state and render one
    /// emission stale, forever. The single async hop re-schedules delivery
    /// behind the property write on the main queue, so the handler reads
    /// post-mutation state.
    ///
    /// This is the ONE sanctioned home for that deferral (gap G19): the three
    /// ad-hoc `DispatchQueue.main.async` blocks it replaced each re-derived
    /// the trick without naming the willSet timing problem, which made every
    /// one of them look like a candidate for "simplification" back into a
    /// stale read.
    func afterMutationSettles() -> AnyPublisher<Output, Never> {
        receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}
