// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// "Check the buttons" and "Help support this controller" as intents. Each
/// page opens its work as it appears (`pageAppeared`) and ends it as it goes.
package extension AppModel {

    /// The step on screen is left as it was.
    func skipButtonCheckStep() {
        input.paths.buttonCheck.send(.skip)
    }

    /// The model's own order again, its stored remap dropped, from the top.
    func resetButtonCheck() {
        input.paths.buttonCheck.send(.reset)
    }

    /// From the top, keeping what is stored.
    func restartButtonCheck() {
        input.paths.buttonCheck.send(.restart)
    }

    /// The step on screen keeps the reports it saw.
    func nextSupportStep() {
        input.paths.support.send(.next)
    }

    func skipSupportStep() {
        input.paths.support.send(.skip)
    }
}
