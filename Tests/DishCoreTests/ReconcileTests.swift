// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The pure reconcile decision logic (contract §Enriched heartbeat ack): the
// drift trigger ((epoch,bitmap) vs applied), the GET converge decision, and
// the late-slot converge diff. Ports the dish-linux test_reconcile.cpp cases
// (themselves the dish-windows test_session_reconcile ports).

import XCTest
import DishCore

final class ReconcileTests: XCTestCase {

    // MARK: - expectedBitmap

    func testExpectedBitmapSetsOneBitPerRegisteredControllerIndex() {
        XCTAssertEqual(expectedBitmap([]), 0)
        XCTAssertEqual(expectedBitmap([DesiredSlot(ctrlIdx: 0, type: 0)]), 0x0001)
        XCTAssertEqual(
            expectedBitmap([DesiredSlot(ctrlIdx: 0, type: 0), DesiredSlot(ctrlIdx: 2, type: 0)]),
            0x0005
        )
        XCTAssertEqual(expectedBitmap([DesiredSlot(ctrlIdx: 15, type: 0)]), 0x8000)
        // Out-of-range indices (>15) don't set a bit.
        XCTAssertEqual(expectedBitmap([DesiredSlot(ctrlIdx: 16, type: 0)]), 0x0000)
    }

    // MARK: - reconcileNeeded (the heartbeat-ack drift trigger)

    func testNoEnrichedAckYetNeverReconciles() {
        // serverEpoch < 0 means no enriched ack has been seen.
        XCTAssertFalse(reconcileNeeded(serverEpoch: -1, serverBitmap: -1, lastAppliedEpoch: 3, expectedBitmap: 0x0001))
    }

    func testEpochDriftTriggers() {
        XCTAssertTrue(reconcileNeeded(serverEpoch: 4, serverBitmap: 0x0001, lastAppliedEpoch: 3, expectedBitmap: 0x0001))
    }

    func testBitmapDriftAtMatchingEpochTriggers() {
        // The server lost controller 1 (bitmap 0x0001 vs our expected 0x0003).
        XCTAssertTrue(reconcileNeeded(serverEpoch: 3, serverBitmap: 0x0001, lastAppliedEpoch: 3, expectedBitmap: 0x0003))
    }

    func testEpochAndBitmapBothMatchingNeedsNoReconcile() {
        XCTAssertFalse(reconcileNeeded(serverEpoch: 3, serverBitmap: 0x0003, lastAppliedEpoch: 3, expectedBitmap: 0x0003))
    }

    func testUnknownBitmapSkipsTheBitmapArm() {
        // serverBitmap < 0 means unknown; only the epoch arm decides.
        XCTAssertFalse(reconcileNeeded(serverEpoch: 3, serverBitmap: -1, lastAppliedEpoch: 3, expectedBitmap: 0x0003))
        XCTAssertTrue(reconcileNeeded(serverEpoch: 4, serverBitmap: -1, lastAppliedEpoch: 3, expectedBitmap: 0x0003))
    }

    // MARK: - appliedMatchesDesired (the GET converge decision)

    func testIdenticalSetsMatch() {
        let desired = [DesiredSlot(ctrlIdx: 0, type: 0), DesiredSlot(ctrlIdx: 1, type: 1)]
        let applied = [
            AppliedSlot(ctrlIdx: 0, appliedType: 0, active: true),
            AppliedSlot(ctrlIdx: 1, appliedType: 1, active: true)
        ]
        XCTAssertTrue(appliedMatchesDesired(desired: desired, applied: applied))
    }

    func testATypeMismatchForcesRePut() {
        let desired = [DesiredSlot(ctrlIdx: 0, type: 1)] // want DS4
        let applied = [AppliedSlot(ctrlIdx: 0, appliedType: 0, active: true)] // got Xbox
        XCTAssertFalse(appliedMatchesDesired(desired: desired, applied: applied))
    }

    func testAnInactiveAppliedSlotIsUnplugged() {
        let desired = [DesiredSlot(ctrlIdx: 0, type: 0)]
        let applied = [AppliedSlot(ctrlIdx: 0, appliedType: 0, active: false)] // server says inactive
        XCTAssertFalse(appliedMatchesDesired(desired: desired, applied: applied))
    }

    func testAMissingDesiredSlotForcesRePut() {
        let desired = [DesiredSlot(ctrlIdx: 0, type: 0), DesiredSlot(ctrlIdx: 1, type: 0)]
        let applied = [AppliedSlot(ctrlIdx: 0, appliedType: 0, active: true)] // server missing slot 1
        XCTAssertFalse(appliedMatchesDesired(desired: desired, applied: applied))
    }

    func testAMouseGrantMismatchForcesRePut() {
        // Even when slots line up, wants≠granted (the grant is only computed
        // at session PUT) forces the converge.
        let desired = [DesiredSlot(ctrlIdx: 0, type: 0)]
        let applied = [AppliedSlot(ctrlIdx: 0, appliedType: 0, active: true)]
        XCTAssertTrue(appliedMatchesDesired(desired: desired, applied: applied, mouseWantsVsGrantedMatch: true))
        XCTAssertFalse(appliedMatchesDesired(desired: desired, applied: applied, mouseWantsVsGrantedMatch: false))
    }

    // MARK: - lateSlotConverge (slots that change during the PUT round-trip)

    func testNothingChangedNeedsNoFollowUps() {
        let sent = [DesiredSlot(ctrlIdx: 0, type: 0)]
        let converge = lateSlotConverge(sent: sent, desired: sent)
        XCTAssertTrue(converge.resyncs.isEmpty)
        XCTAssertTrue(converge.removes.isEmpty)
    }

    func testANewlyAddedSlotResyncs() {
        let sent = [DesiredSlot(ctrlIdx: 0, type: 0)]
        let desired = [DesiredSlot(ctrlIdx: 0, type: 0), DesiredSlot(ctrlIdx: 1, type: 1)]
        let converge = lateSlotConverge(sent: sent, desired: desired)
        XCTAssertEqual(converge.resyncs, [1])
        XCTAssertTrue(converge.removes.isEmpty)
    }

    func testAChangedTypeResyncs() {
        let sent = [DesiredSlot(ctrlIdx: 0, type: 0)]
        let desired = [DesiredSlot(ctrlIdx: 0, type: 1)] // type changed
        let converge = lateSlotConverge(sent: sent, desired: desired)
        XCTAssertEqual(converge.resyncs, [0])
        XCTAssertTrue(converge.removes.isEmpty)
    }

    func testARemovedSlotDeletes() {
        let sent = [DesiredSlot(ctrlIdx: 0, type: 0), DesiredSlot(ctrlIdx: 1, type: 0)]
        let desired = [DesiredSlot(ctrlIdx: 0, type: 0)]
        let converge = lateSlotConverge(sent: sent, desired: desired)
        XCTAssertTrue(converge.resyncs.isEmpty)
        XCTAssertEqual(converge.removes, [1])
    }
}
