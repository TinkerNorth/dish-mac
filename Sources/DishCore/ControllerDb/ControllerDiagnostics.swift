// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The levels Diagnostics tests below the wire (section 9): what the
// hardware showed at attach against the record's `expect`, which known
// issues apply to this Mac, the last Direct write's verdict, and the
// person's own answer after each inspector test.

import Foundation

// MARK: - Identity: the expect check

/// What the Direct path could see of the pad at attach; nil is "not seen".
public struct ObservedEndpoints: Equatable, Sendable {
    public let input: Bool?
    public let output: Bool?

    public init(input: Bool?, output: Bool?) {
        self.input = input
        self.output = output
    }
}

/// One line per expectation the hardware broke, in the contract's form
/// ("endpoints.out: expected true, found false"). An expectation of
/// unknown, and a fact the path cannot see, are not compared.
public func expectMismatches(_ expect: ControllerExpect, observed: ObservedEndpoints) -> [String] {
    let pairs = [("endpoints.in", expect.endpointIn, observed.input), ("endpoints.out", expect.endpointOut, observed.output)]
    return pairs.compactMap { name, expected, found in
        guard let expected, let found, expected != found else { return nil }
        return "\(name): expected \(expected), found \(found)"
    }
}

// MARK: - Support: the issues that apply here

/// The Mac's key under an issue's `os`.
public let macOSIssueKey = "macos"

/// The host an issue is matched against.
public struct IssueHost: Equatable, Sendable {
    /// `hw.model`, "Mac14,2".
    public let model: String
    public let osMajor: Int

    public init(model: String, osMajor: Int) {
        self.model = model
        self.osMajor = osMajor
    }
}

/// The `status` of an issue that is still shown.
public let openIssueStatus = "open"

/// An issue applies while it is open, when its transport is the pad's or
/// any, its device is this Mac or none, and its `os` names this macOS or
/// nothing.
public func issuesApplying(_ issues: [ControllerIssue], transport: ControllerTransport?, host: IssueHost) -> [ControllerIssue] {
    issues.filter { issue in
        let open = issue.status == openIssueStatus
        let transportFits = issue.transport == nil || issue.transport == transport
        let deviceFits = issue.device.map { $0 == host.model } ?? true
        let osFits = issue.os.isEmpty || issue.os[macOSIssueKey] == host.osMajor
        return open && transportFits && deviceFits && osFits
    }
}

// MARK: - Client to pad: the last write

/// The verdict of one Direct write: how it left, which report, and what
/// IOKit said.
public struct DirectWriteVerdict: Equatable, Sendable {
    public let route: ControllerOutputRoute
    public let reportId: UInt8
    public let ok: Bool
    /// IOKit's name for the failure; nil when it went.
    public let error: String?
    /// Milliseconds since the Unix epoch.
    public let atMs: Int64

    public init(route: ControllerOutputRoute, reportId: UInt8, status: Int32, atMs: Int64) {
        self.route = route
        self.reportId = reportId
        ok = status == ioReturnSuccess
        error = ok ? nil : ioReturnName(status)
        self.atMs = atMs
    }
}

let ioReturnSuccess: Int32 = 0

/// `IOReturn.h`'s names for the answers a HID or USB write gives.
private let ioReturnNames: [UInt32: String] = [
    0xE000_02BC: "kIOReturnError",
    0xE000_02C0: "kIOReturnNoDevice",
    0xE000_02C2: "kIOReturnBadArgument",
    0xE000_02C5: "kIOReturnExclusiveAccess",
    0xE000_02C7: "kIOReturnUnsupported",
    0xE000_02CD: "kIOReturnNotOpen",
    0xE000_02D6: "kIOReturnTimeout",
    0xE000_02D8: "kIOReturnNotReady",
    0xE000_02E2: "kIOReturnNotPermitted",
    0xE000_02EB: "kIOReturnAborted",
    0xE000_02ED: "kIOReturnNotResponding",
    0xE000_4051: "kIOUSBPipeStalled"
]

/// IOKit's name, else the code in hex.
public func ioReturnName(_ status: Int32) -> String {
    let bits = UInt32(bitPattern: status)
    return ioReturnNames[bits] ?? String(format: "0x%08x", bits)
}

// MARK: - Pad: the person's answer

/// The inspector's tests, by the ids the bundle carries, in the contract's
/// order. The contract's `lamp.on` and `lamp.pulse` are not here: no Mac
/// path reaches a pad's mic lamp.
public enum InspectorTest: String, CaseIterable, Equatable, Sendable {
    case rumbleWeak = "rumble.weak"
    case rumbleStrong = "rumble.strong"
    case rumbleBoth = "rumble.both"
    case triggerRumbleLeft = "triggerRumble.left"
    case triggerRumbleRight = "triggerRumble.right"
    case triggerRumbleBoth = "triggerRumble.both"
    case lightbarCycle = "lightbar.cycle"
    case playerLedsCycle = "playerLeds.cycle"
    case triggerPulse = "trigger.pulse"
    case tone = "tone.play"
    case haptics = "haptics.play"
    case microphone = "mic.level"
    case stickDrift = "stick.drift"
    case stickRange = "stick.range"
}

public enum OutcomeResult: String, CaseIterable, Equatable, Sendable {
    case worked
    case didNotWork
}

/// "Did it work?" answered.
public struct TestOutcome: Equatable, Sendable {
    public let test: InspectorTest
    public let result: OutcomeResult
    /// Milliseconds since the Unix epoch.
    public let atMs: Int64

    public init(test: InspectorTest, result: OutcomeResult, atMs: Int64) {
        self.test = test
        self.result = result
        self.atMs = atMs
    }
}

public enum TestOutcomeLimits {
    /// Per controller, for the run.
    public static let perPad = 20
}

/// The answers oldest first, the newest kept when the list is full.
public func appendingOutcome(_ outcomes: [TestOutcome], _ outcome: TestOutcome, limit: Int = TestOutcomeLimits.perPad) -> [TestOutcome] {
    Array((outcomes + [outcome]).suffix(max(limit, 0)))
}

/// A test that ran to its end and waits for its answer.
public struct EndedTest: Equatable, Sendable {
    public let test: InspectorTest
    /// Milliseconds since the Unix epoch.
    public let atMs: Int64

    public init(test: InspectorTest, atMs: Int64) {
        self.test = test
        self.atMs = atMs
    }
}

/// "Did it work?" on one pad, one answer per run (the contract's bench,
/// rule 4): the test running now, the one that ended and waits for its
/// answer, and the answers, each stamped with the time its test ended.
public struct PadTestLedger: Equatable, Sendable {
    public private(set) var running: InspectorTest?
    public private(set) var asking: EndedTest?
    /// Oldest first, the newest twenty.
    public private(set) var answers: [TestOutcome] = []

    public init() {}

    /// A new run replaces any question still unanswered.
    public mutating func started(_ test: InspectorTest) {
        running = test
        asking = nil
    }

    /// The end of a run another run replaced asks nothing.
    public mutating func ended(_ test: InspectorTest, atMs: Int64) {
        guard running == test else { return }
        running = nil
        asking = EndedTest(test: test, atMs: atMs)
    }

    /// Nothing while no question waits.
    public mutating func answered(worked: Bool) {
        guard let asking else { return }
        let outcome = TestOutcome(test: asking.test, result: worked ? .worked : .didNotWork, atMs: asking.atMs)
        answers = appendingOutcome(answers, outcome)
        self.asking = nil
    }
}
