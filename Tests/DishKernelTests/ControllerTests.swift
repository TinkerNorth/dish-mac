// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import DishKernelProbes
import XCTest

final class ControllerTests: XCTestCase {

    func testStartAppliesTheUpstreamsCurrentValue() {
        let source = StateSource<Int>(initial: 3)
        let controller = RecordingController(upstream: source.statePublisher)
        controller.start()
        XCTAssertEqual(controller.applied, [3])
    }

    func testEveryUpstreamChangeIsApplied() {
        let source = StateSource<Int>(initial: 3)
        let controller = RecordingController(upstream: source.statePublisher)
        controller.start()
        source.setState(4)
        source.setState(5)
        XCTAssertEqual(controller.applied, [3, 4, 5])
    }

    func testStartIsIdempotent() {
        let source = StateSource<Int>(initial: 3)
        let controller = RecordingController(upstream: source.statePublisher)
        controller.start()
        controller.start()
        XCTAssertEqual(controller.applied, [3])
        XCTAssertEqual(controller.startCount, 1)
    }

    func testStopEndsTheCollection() {
        let source = StateSource<Int>(initial: 3)
        let controller = RecordingController(upstream: source.statePublisher)
        controller.start()
        controller.stop()
        source.setState(4)
        XCTAssertEqual(controller.applied, [3])
        XCTAssertFalse(controller.isStarted)
    }

    func testARestartReAppliesTheCurrentValueAndReArms() {
        let source = StateSource<Int>(initial: 3)
        let controller = RecordingController(upstream: source.statePublisher)
        controller.start()
        controller.stop()
        source.setState(9)
        controller.start()
        XCTAssertEqual(controller.applied, [3, 9])
        XCTAssertEqual(controller.startCount, 2)
    }

    func testNothingIsAppliedBeforeStart() {
        let source = StateSource<Int>(initial: 3)
        let controller = RecordingController(upstream: source.statePublisher)
        source.setState(4)
        XCTAssertEqual(controller.applied, [])
    }
}
