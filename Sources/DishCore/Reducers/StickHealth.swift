// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The input inspector's two stick tests, as pure math over captured samples:
// the drift test averages how far a stick rests from centre when nobody is
// touching it, and the range test measures how far it reaches and how round
// its gate is. dish-android's StickHealth.kt and dish-linux's StickHealth.h
// hold the same numbers, so the three clients read one stick the same way.

import Foundation

/// One stick reading, each axis a fraction of full travel (-1...1).
public struct StickSample: Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let centre = StickSample(x: 0, y: 0)

    public var magnitude: Float {
        (x * x + y * y).squareRoot()
    }
}

/// The mean resting offset: the stick was supposed to be untouched.
public func stickDrift(_ samples: [StickSample]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(Float(0)) { $0 + $1.magnitude } / Float(samples.count)
}

public enum StickHealth {
    /// A dead zone with headroom over the measured drift, floored at sensor
    /// noise and capped where a stick is faulty rather than drifting.
    public static let deadzoneHeadroom: Float = 1.5
    public static let deadzoneFloor: Float = 0.04
    public static let deadzoneCeiling: Float = 0.30
    /// Angle buckets for the roundness sweep: coarse enough that an ordinary
    /// hand sweep fills every one, fine enough to catch a flat spot.
    public static let rimBuckets = 16
    /// Only a sample this far out describes the gate; anything closer in is
    /// where the stick happened to be, not how far it can go.
    public static let rimThreshold: Float = 0.5
    /// Fewer buckets visited than this and the user never finished the
    /// circle, so a roundness figure would be noise.
    public static let rimBucketsForVerdict = 12
    /// How long each test captures for: drift needs the stick at rest for a
    /// moment, range needs time to sweep both sticks round.
    public static let driftCaptureMs: Int64 = 3000
    public static let rangeCaptureMs: Int64 = 8000
}

/// In whole percent: the drift with headroom, bounded.
public func suggestedDeadzone(drift: Float) -> Float {
    let withHeadroom = drift * StickHealth.deadzoneHeadroom
    let bounded = min(max(withHeadroom, StickHealth.deadzoneFloor), StickHealth.deadzoneCeiling)
    return (bounded * 100).rounded() / 100
}

/// The furthest the stick reached in each direction around the circle.
public struct RimSweep: Hashable, Sendable {
    public var reach = [Float](repeating: 0, count: StickHealth.rimBuckets)
    public var seen = [Bool](repeating: false, count: StickHealth.rimBuckets)

    public init() {}

    /// The buckets run round the circle from straight left, where the angle
    /// wraps, so straight left lands in the last bucket, never one past it.
    public static func bucket(of sample: StickSample) -> Int {
        let angle = atan2(Double(sample.y), Double(sample.x))
        let turn = (angle + .pi) / (2 * .pi)
        let bucket = Int(turn * Double(StickHealth.rimBuckets))
        return min(max(bucket, 0), StickHealth.rimBuckets - 1)
    }

    public mutating func add(_ sample: StickSample) {
        let reach = sample.magnitude
        guard reach >= StickHealth.rimThreshold else { return }
        let bucket = Self.bucket(of: sample)
        seen[bucket] = true
        self.reach[bucket] = max(self.reach[bucket], reach)
    }

    var coverage: (buckets: Int, totalReach: Float) {
        var buckets = 0
        var total: Float = 0
        for index in seen.indices where seen[index] {
            buckets += 1
            total += reach[index]
        }
        return (buckets, total)
    }

    /// The largest deviation from the mean rim reach, as a fraction of it.
    /// Nil until the sweep covered enough of the circle, or when the rim
    /// never moved.
    public var circularityError: Float? {
        let covered = coverage
        guard covered.buckets >= StickHealth.rimBucketsForVerdict else { return nil }
        let meanReach = covered.totalReach / Float(covered.buckets)
        guard meanReach > 0 else { return nil }
        var worst: Float = 0
        for index in seen.indices where seen[index] {
            worst = max(worst, abs(reach[index] - meanReach))
        }
        return worst / meanReach
    }
}

/// Each axis' extremes and the gate's roundness.
public struct StickEnvelope: Hashable, Sendable {
    public var minX: Float = 0
    public var maxX: Float = 0
    public var minY: Float = 0
    public var maxY: Float = 0
    public var circularityError: Float?

    public init(minX: Float = 0, maxX: Float = 0, minY: Float = 0, maxY: Float = 0, circularityError: Float? = nil) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.circularityError = circularityError
    }

    /// The rail the stick struggles to reach is the one that matters in a
    /// game; a rail never reached in its own direction floors at zero.
    public var worstReach: Float {
        max(min(-minX, maxX, -minY, maxY), 0)
    }
}

public func stickEnvelope(_ samples: [StickSample]) -> StickEnvelope {
    var envelope = StickEnvelope()
    var rim = RimSweep()
    for sample in samples {
        envelope.minX = min(envelope.minX, sample.x)
        envelope.maxX = max(envelope.maxX, sample.x)
        envelope.minY = min(envelope.minY, sample.y)
        envelope.maxY = max(envelope.maxY, sample.y)
        rim.add(sample)
    }
    envelope.circularityError = rim.circularityError
    return envelope
}

public enum StickTestKind: Hashable, Sendable {
    case drift
    case range

    public var captureMs: Int64 {
        switch self {
        case .drift: StickHealth.driftCaptureMs
        case .range: StickHealth.rangeCaptureMs
        }
    }
}

/// What a finished test found. `samples` is how many polls the capture
/// took; none means the pad sent nothing and the figures measure nothing.
public struct StickTestResult: Hashable, Sendable {
    public var kind: StickTestKind
    public var samples: Int
    public var driftLeft: Float = 0
    public var driftRight: Float = 0
    public var suggestedDeadzone: Float = 0
    public var reachLeft: Float = 0
    public var reachRight: Float = 0
    public var circularityLeft: Float?
    public var circularityRight: Float?

    public init(kind: StickTestKind, samples: Int) {
        self.kind = kind
        self.samples = samples
    }
}

/// One running test: both sticks' samples and when the capture ends. The
/// clock is passed in, so the whole test runs on virtual time.
public struct StickTest: Hashable, Sendable {
    public let kind: StickTestKind
    public let endsAtMs: Int64
    public private(set) var left: [StickSample] = []
    public private(set) var right: [StickSample] = []

    public init(kind: StickTestKind, startMs: Int64) {
        self.kind = kind
        endsAtMs = startMs + kind.captureMs
    }

    public mutating func add(left leftSample: StickSample, right rightSample: StickSample) {
        left.append(leftSample)
        right.append(rightSample)
    }

    public func finished(at nowMs: Int64) -> Bool {
        nowMs >= endsAtMs
    }

    /// Whole seconds left plus one, so a running capture never reads zero
    /// while it is still taking samples.
    public func secondsLeft(at nowMs: Int64) -> Int {
        Int((endsAtMs - nowMs) / 1000 + 1)
    }

    public func result() -> StickTestResult {
        switch kind {
        case .drift: driftResult()
        case .range: rangeResult()
        }
    }

    /// The dead zone is sized for the worse stick: one setting covers both.
    private func driftResult() -> StickTestResult {
        var result = StickTestResult(kind: .drift, samples: left.count)
        result.driftLeft = stickDrift(left)
        result.driftRight = stickDrift(right)
        result.suggestedDeadzone = suggestedDeadzone(drift: max(result.driftLeft, result.driftRight))
        return result
    }

    private func rangeResult() -> StickTestResult {
        let leftEnvelope = stickEnvelope(left)
        let rightEnvelope = stickEnvelope(right)
        var result = StickTestResult(kind: .range, samples: left.count)
        result.reachLeft = leftEnvelope.worstReach
        result.reachRight = rightEnvelope.worstReach
        result.circularityLeft = leftEnvelope.circularityError
        result.circularityRight = rightEnvelope.circularityError
        return result
    }
}

public enum StickTestPhase: Hashable, Sendable {
    case idle
    case running
    case done
}

/// The inspector's one stick-test slot: nothing yet, a test running, or the
/// last test's result. Starting a test replaces whatever was there.
public struct StickBench: Hashable, Sendable {
    public private(set) var running: StickTest?
    public private(set) var result: StickTestResult?

    public init() {}

    public mutating func start(_ kind: StickTestKind, nowMs: Int64) {
        running = StickTest(kind: kind, startMs: nowMs)
    }

    /// One poll's sticks, taken only while a test runs.
    public mutating func sample(left: StickSample, right: StickSample) {
        running?.add(left: left, right: right)
    }

    /// The poll that reaches a running test's end turns it into the result.
    public mutating func advance(nowMs: Int64) {
        guard let test = running, test.finished(at: nowMs) else { return }
        result = test.result()
        running = nil
    }

    public var phase: StickTestPhase {
        if running != nil { return .running }
        return result != nil ? .done : .idle
    }

    /// The running test's kind, else the last result's.
    public var kind: StickTestKind {
        running?.kind ?? result?.kind ?? .drift
    }

    public func secondsLeft(at nowMs: Int64) -> Int {
        running?.secondsLeft(at: nowMs) ?? 0
    }
}
