// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import XCTest
@testable import DishEngine

/// The handler's pieces, each checked against a file: the record's shape,
/// the signal names, the one-time install, and the crash log's lifecycle.
final class CrashHandlerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dish-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var log: CrashLog {
        CrashLog(url: directory.appendingPathComponent("crash.log"))
    }

    // MARK: - The record

    func testARecordNamesTheSignalAndCarriesTheFrames() {
        let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let depth = CrashHandler.captureFrames()
        CrashHandler.writeRecord(to: fd, signal: SIGSEGV, depth: depth)
        close(fd)
        let lines = log.read().split(separator: "\n")
        XCTAssertEqual(lines.first, "--- dish crash: SIGSEGV")
        XCTAssertGreaterThan(lines.count, 2, "the frames follow the marker")
        XCTAssertGreaterThan(depth, 1)
    }

    func testEveryArmedSignalHasItsName() {
        XCTAssertEqual(CrashHandler.signalName(SIGSEGV).description, "SIGSEGV\n")
        XCTAssertEqual(CrashHandler.signalName(SIGABRT).description, "SIGABRT\n")
        XCTAssertEqual(CrashHandler.signalName(SIGBUS).description, "SIGBUS\n")
        XCTAssertEqual(CrashHandler.signalName(SIGFPE).description, "SIGFPE\n")
        XCTAssertEqual(CrashHandler.signalName(SIGILL).description, "SIGILL\n")
        XCTAssertEqual(CrashHandler.signalName(SIGTERM).description, "signal\n", "an unarmed signal still writes a record")
        XCTAssertEqual(CrashHandler.signals, [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL])
    }

    func testAShortWriteIsRetriedAndABadDescriptorEndsTheAttempt() {
        let fd = open(log.path, O_WRONLY | O_CREAT, 0o600)
        CrashHandler.writeAll(fd, "dish crashed: ")
        CrashHandler.writeAll(fd, "SIGBUS\n")
        close(fd)
        XCTAssertEqual(log.read(), "dish crashed: SIGBUS\n")
        CrashHandler.writeAll(-1, "nowhere")
    }

    // MARK: - The install

    func testTheHandlersArmOncePerProcessAndMakeTheLogsDirectory() {
        let nested = CrashLog(url: directory.appendingPathComponent("deeper/Dish/crash.log"))
        let first = CrashHandler.install(log: nested)
        let second = CrashHandler.install(log: nested)
        XCTAssertFalse(first && second, "the second call never re-arms")
        XCTAssertFalse(second)
        XCTAssertNotNil(CrashHandler.installedPath)
        if first {
            XCTAssertEqual(CrashHandler.installedPath, nested.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.url.deletingLastPathComponent().path))
            var current = sigaction()
            sigaction(SIGSEGV, nil, &current)
            XCTAssertNotNil(current.__sigaction_u.__sa_handler, "SIGSEGV has a handler")
            XCTAssertEqual(current.sa_flags & SA_ONSTACK, SA_ONSTACK, "a stack overflow still has room to run it")
        }
    }

    // MARK: - The log

    func testTheStandardLogLivesBesideTheSystemsLogs() {
        let home = URL(fileURLWithPath: "/Users/laura", isDirectory: true)
        XCTAssertEqual(CrashLog.standard(home: home).path, "/Users/laura/Library/Logs/Dish/crash.log")
    }

    func testAnEmptyOrMissingLogDoesNotExist() throws {
        XCTAssertFalse(log.exists)
        XCTAssertEqual(log.read(), "")
        try Data().write(to: log.url)
        XCTAssertFalse(log.exists, "an empty file is no crash")
        try Data("--- dish crash: SIGABRT\n".utf8).write(to: log.url)
        XCTAssertTrue(log.exists)
        XCTAssertEqual(log.read(), "--- dish crash: SIGABRT\n")
    }

    func testDiscardingRemovesTheLogAndAnAbsentLogIsAlreadyDiscarded() throws {
        XCTAssertTrue(log.discard(), "already gone is the requested end state")
        try Data("x".utf8).write(to: log.url)
        XCTAssertTrue(log.discard())
        XCTAssertFalse(log.exists)
    }
}
