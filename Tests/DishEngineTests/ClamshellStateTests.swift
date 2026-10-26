// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// The lid reader against the real registry: it says what `ioreg` says of
/// `IOPMrootDomain`, and a Mac with no lid (a desktop, a CI runner) reads open.
final class ClamshellStateTests: XCTestCase {

    private func ioregClamshellLine() throws -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-k", IOKitClamshellState.clamshellKey, "-d", "1"]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = try XCTUnwrap(String(bytes: output, encoding: .utf8))
        let lines = text.split(separator: "\n")
        return lines.first { $0.contains("\"\(IOKitClamshellState.clamshellKey)\" =") }.map(String.init)
    }

    func testTheReaderSaysWhatTheRegistrySaysOfTheLid() throws {
        let line = try ioregClamshellLine()
        let closedPerIoreg = line?.hasSuffix("= Yes") ?? false
        XCTAssertEqual(IOKitClamshellState().lidIsClosed(), closedPerIoreg, line ?? "no lid on this Mac: reads open")
    }
}
