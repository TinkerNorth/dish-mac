// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Every (phase, event) pair of the input-source machine, with the phase it
/// lands in and the effects it returns. A new phase or event fails to
/// compile in the reducer; a changed row fails here.
final class InputSourceMachineTableTests: XCTestCase {

    private struct Row {
        let event: InputSourceEvent
        let phase: InputSourcePhase
        let effects: [InputSourceEffect]
    }

    private static let shownFacts = PadPathFacts(model: nil, decodable: true, gameController: .shows, stored: nil)
    private static let n64Facts = PadPathFacts(
        model: directModel(vendorId: 0x057E, productId: 0x2019), decodable: true, gameController: .shows, stored: nil
    )

    private static let events: [InputSourceEvent] = [
        .connected(shownFacts), .gameControllerResolved(shows: true), .standardInputChanged(nowMs: 1000),
        .directInputChanged(nowMs: 1000), .checkStarted(nowMs: 1000), .tick(nowMs: 1000), .userPicked(.direct), .disconnected
    ]

    private func state(after events: [InputSourceEvent]) -> InputSourceState {
        events.reduce(InputSourceState.initial) { reduceInputSource($0, $1).next }
    }

    private func assertRows(from start: InputSourceState, _ rows: [Row], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rows.map(\.event), Self.events, "one row per event, in order", file: file, line: line)
        for row in rows {
            let reduction = reduceInputSource(start, row.event)
            XCTAssertEqual(reduction.next.phase, row.phase, "\(row.event)", file: file, line: line)
            XCTAssertEqual(reduction.effects, row.effects, "\(row.event)", file: file, line: line)
        }
    }

    private func rows(_ outcomes: [(InputSourcePhase, [InputSourceEffect])]) -> [Row] {
        zip(Self.events, outcomes).map { Row(event: $0, phase: $1.0, effects: $1.1) }
    }

    func testDisconnectedOnlyAConnectMeansAnything() {
        assertRows(from: .initial, rows([
            (.forwarding(.standard), [.forward(.standard)]),
            (.disconnected, []), (.disconnected, []), (.disconnected, []),
            (.disconnected, []), (.disconnected, []), (.disconnected, []), (.disconnected, [])
        ]))
    }

    func testAwaitingGameControllerOnlyItsAnswerOrADisconnectMoves() {
        let pending = PadPathFacts(model: nil, decodable: true, gameController: .pending, stored: nil)
        assertRows(from: state(after: [.connected(pending)]), rows([
            (.awaitingGameController, []),
            (.forwarding(.standard), [.forward(.standard)]),
            (.awaitingGameController, []), (.awaitingGameController, []), (.awaitingGameController, []),
            (.awaitingGameController, []), (.awaitingGameController, []),
            (.disconnected, [])
        ]))
    }

    func testForwardingStandard() {
        assertRows(from: state(after: [.connected(Self.shownFacts)]), rows([
            (.forwarding(.standard), []), (.forwarding(.standard), []), (.forwarding(.standard), []),
            (.forwarding(.standard), []), (.forwarding(.standard), []), (.forwarding(.standard), []),
            (.forwarding(.direct), [.forward(.direct), .remember(.direct)]),
            (.disconnected, [.stopForwarding])
        ]))
    }

    func testForwardingDirect() {
        assertRows(from: state(after: [.connected(Self.n64Facts)]), rows([
            (.forwarding(.direct), []), (.forwarding(.direct), []), (.forwarding(.direct), []),
            (.forwarding(.direct), []), (.forwarding(.direct), []), (.forwarding(.direct), []),
            (.forwarding(.direct), []),
            (.disconnected, [.stopForwarding])
        ]))
    }

    func testForwardingWithACheckRunning() {
        assertRows(from: state(after: [.connected(Self.shownFacts), .checkStarted(nowMs: 0)]), rows([
            (.forwarding(.standard), []), (.forwarding(.standard), []),
            (.forwarding(.standard), [.verdict(.standardWorks, offer: .none)]),
            (.forwarding(.standard), []), (.forwarding(.standard), []), (.forwarding(.standard), []),
            (.forwarding(.direct), [.forward(.direct), .remember(.direct)]),
            (.disconnected, [.stopForwarding])
        ]))
    }

    func testUnreadableOnlyADisconnectMoves() {
        let unreadable = PadPathFacts(model: nil, decodable: false, gameController: .doesNotShow, stored: nil)
        let start = state(after: [.connected(unreadable)])
        assertRows(from: start, rows([
            (.unreadable, []), (.unreadable, []), (.unreadable, []), (.unreadable, []),
            (.unreadable, []), (.unreadable, []), (.unreadable, []),
            (.disconnected, [])
        ]))
        XCTAssertNil(reduceInputSource(start, .checkStarted(nowMs: 0)).next.check, "nothing is forwarded, so there is nothing to check")
    }
}
