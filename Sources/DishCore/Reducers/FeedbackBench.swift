// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Diagnostics bench's feedback tests, as the contract's "The bench" fixes
// them (dish-android's strengths and times, so a pad feels the same test on
// every client): what each test writes and when, which items a pad's path
// carries, and the rules that keep the game's state. Rumble and trigger
// rumble are transient and simply stop. The light bar, the player LEDs and
// the adaptive triggers are state the game set: a test takes the surface,
// a value the game sends meanwhile is remembered instead of written, and the
// test's end writes back the game's newest value, or the surface's idle
// state when the game never set it.

import Foundation

// MARK: - Rumble

public enum BuzzMotor: CaseIterable, Equatable, Sendable {
    case weak
    case strong
    case both
}

public struct TestBuzz: Equatable, Sendable {
    public var strong: UInt16
    public var weak: UInt16
    public var durationMs: UInt16

    public init(strong: UInt16, weak: UInt16, durationMs: UInt16) {
        self.strong = strong
        self.weak = weak
        self.durationMs = durationMs
    }

    public static let magnitude: UInt16 = 48000
    public static let durationMs: UInt16 = 400
}

public func testBuzz(for motor: BuzzMotor) -> TestBuzz {
    switch motor {
    case .weak: TestBuzz(strong: 0, weak: TestBuzz.magnitude, durationMs: TestBuzz.durationMs)
    case .strong: TestBuzz(strong: TestBuzz.magnitude, weak: 0, durationMs: TestBuzz.durationMs)
    case .both: TestBuzz(strong: TestBuzz.magnitude, weak: TestBuzz.magnitude, durationMs: TestBuzz.durationMs)
    }
}

// MARK: - Trigger rumble

public enum TriggerMotor: CaseIterable, Equatable, Sendable {
    case left
    case right
    case both
}

/// The trigger motors' buzz, at the rumble test's strength and time.
public struct TestTriggerBuzz: Equatable, Sendable {
    public let left: UInt16
    public let right: UInt16
    public let durationMs: UInt16

    public init(left: UInt16, right: UInt16, durationMs: UInt16) {
        self.left = left
        self.right = right
        self.durationMs = durationMs
    }
}

public func testTriggerBuzz(for motor: TriggerMotor) -> TestTriggerBuzz {
    switch motor {
    case .left: TestTriggerBuzz(left: TestBuzz.magnitude, right: 0, durationMs: TestBuzz.durationMs)
    case .right: TestTriggerBuzz(left: 0, right: TestBuzz.magnitude, durationMs: TestBuzz.durationMs)
    case .both: TestTriggerBuzz(left: TestBuzz.magnitude, right: TestBuzz.magnitude, durationMs: TestBuzz.durationMs)
    }
}

// MARK: - The state surfaces' tests

public struct LightbarColor: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Red, green, then blue, a step each.
public let lightbarCycle = [
    LightbarColor(r: 0xFF, g: 0, b: 0),
    LightbarColor(r: 0, g: 0xFF, b: 0),
    LightbarColor(r: 0, g: 0, b: 0xFF)
]

/// The players whose patterns the cycle lights, a step each. Every Mac path
/// lights a pad's player LEDs by player number (GameController's player
/// index), never by single LED, so the cycle walks the four players where
/// the contract walks five single-LED masks.
public let playerCycle = [1, 2, 3, 4]

/// One trigger at full rigid resistance: DualSense effect mode 01 (the
/// firmware's continuous resistance), start position 0, force ff.
public let rigidTriggerBlock: [UInt8] = [0x01, 0x00, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]

/// The triggers with no effect on either side, mode 00 in both blocks.
public let idleTriggerEffects = TriggerEffectsCommand(
    controllerIndex: 0,
    left: [UInt8](repeating: 0, count: ProtocolConstants.triggerEffectBlockBytes),
    right: [UInt8](repeating: 0, count: ProtocolConstants.triggerEffectBlockBytes)
)

public enum BenchTiming {
    /// One step of a cycle.
    public static let cycleStepMs: Int64 = 400
    public static let triggerPulseMs: Int64 = 2000
}

// MARK: - The programs

/// The inspector's feedback tests.
public enum FeedbackTest: Hashable, Sendable {
    case rumble(BuzzMotor)
    case triggerRumble(TriggerMotor)
    case lightbarCycle
    case playerCycle
    case triggerPulse

    /// The name the diagnostics file carries.
    public var inspectorTest: InspectorTest {
        switch self {
        case let .rumble(motor): rumbleTestName(motor)
        case let .triggerRumble(motor): triggerRumbleTestName(motor)
        case .lightbarCycle: .lightbarCycle
        case .playerCycle: .playerLedsCycle
        case .triggerPulse: .triggerPulse
        }
    }
}

private func rumbleTestName(_ motor: BuzzMotor) -> InspectorTest {
    switch motor {
    case .weak: .rumbleWeak
    case .strong: .rumbleStrong
    case .both: .rumbleBoth
    }
}

private func triggerRumbleTestName(_ motor: TriggerMotor) -> InspectorTest {
    switch motor {
    case .left: .triggerRumbleLeft
    case .right: .triggerRumbleRight
    case .both: .triggerRumbleBoth
    }
}

/// A state surface a test takes from the game for its length.
public enum BenchSurface: CaseIterable, Equatable, Sendable {
    case lightbar
    case playerLeds
    case triggerEffects
}

/// One write a test makes on the pad.
public enum BenchAction: Equatable, Sendable {
    case rumble(TestBuzz)
    case triggerRumble(TestTriggerBuzz)
    case lightbar(LightbarColor)
    case player(Int)
    case triggerEffects(TriggerEffectsCommand)
}

public struct BenchStep: Equatable, Sendable {
    /// From the test's start.
    public let atMs: Int64
    public let action: BenchAction

    public init(atMs: Int64, action: BenchAction) {
        self.atMs = atMs
        self.action = action
    }
}

/// What a test does: the surface it holds, its writes, and when it ends
/// (the surface goes back and the page asks whether it worked).
public struct BenchProgram: Equatable, Sendable {
    /// Nil for a transient test, which takes nothing from the game.
    public let surface: BenchSurface?
    public let steps: [BenchStep]
    public let durationMs: Int64

    public init(surface: BenchSurface?, steps: [BenchStep], durationMs: Int64) {
        self.surface = surface
        self.steps = steps
        self.durationMs = durationMs
    }
}

public func benchProgram(_ test: FeedbackTest) -> BenchProgram {
    switch test {
    case let .rumble(motor): transientProgram(.rumble(testBuzz(for: motor)))
    case let .triggerRumble(motor): transientProgram(.triggerRumble(testTriggerBuzz(for: motor)))
    case .lightbarCycle: cycleProgram(.lightbar, lightbarCycle.map(BenchAction.lightbar))
    case .playerCycle: cycleProgram(.playerLeds, playerCycle.map(BenchAction.player))
    case .triggerPulse: triggerPulseProgram
    }
}

/// One buzz, which the actuator stops when its time runs out.
private func transientProgram(_ action: BenchAction) -> BenchProgram {
    BenchProgram(surface: nil, steps: [BenchStep(atMs: 0, action: action)], durationMs: Int64(TestBuzz.durationMs))
}

private func cycleProgram(_ surface: BenchSurface, _ actions: [BenchAction]) -> BenchProgram {
    let steps = actions.enumerated().map { index, action in BenchStep(atMs: Int64(index) * BenchTiming.cycleStepMs, action: action) }
    return BenchProgram(surface: surface, steps: steps, durationMs: Int64(actions.count) * BenchTiming.cycleStepMs)
}

private let triggerPulseProgram = BenchProgram(
    surface: .triggerEffects,
    steps: [BenchStep(atMs: 0, action: .triggerEffects(TriggerEffectsCommand(
        controllerIndex: 0,
        left: rigidTriggerBlock,
        right: rigidTriggerBlock
    )))],
    durationMs: BenchTiming.triggerPulseMs
)

// MARK: - Rules 2 and 3: the game's state goes back

/// One state surface of one pad between the game and the bench: the game's
/// newest value, and while a test holds the surface, the idle state the
/// test found it in.
public struct BenchSurfaceState<Value: Equatable & Sendable>: Equatable, Sendable {
    /// Nil while the game never set the surface.
    public private(set) var game: Value?
    public private(set) var held = false
    private var idle: Value?

    public init() {}

    /// The game sent a value: what to write now, or nil while a test holds
    /// the surface and the value waits for the test's end.
    public mutating func gameSent(_ value: Value) -> Value? {
        game = value
        return held ? nil : value
    }

    /// A test takes the surface, with the idle state it goes back to if the
    /// game never set it; a surface already held keeps the idle state its
    /// test found.
    public mutating func take(idle: Value?) {
        guard !held else { return }
        held = true
        self.idle = idle
    }

    /// The test ended: the game's newest value, else the idle state; nil
    /// when no test held the surface or there is nothing to put back.
    public mutating func release() -> Value? {
        guard held else { return nil }
        held = false
        let back = game ?? idle
        idle = nil
        return back
    }
}

// MARK: - Rule 1: offered only where it can land

/// What a pad's path carries, from the composed capabilities of the path it
/// is on now: the facts the game's own writes are gated on.
public struct BenchCarriage: Equatable, Sendable {
    public var rumble: Bool
    public var triggerRumble: Bool
    public var lightbar: Bool
    public var playerLeds: Bool
    public var triggerEffects: Bool
    public var speaker: Bool
    public var hapticLanes: Bool
    public var mic: Bool

    public init(
        rumble: Bool = false,
        triggerRumble: Bool = false,
        lightbar: Bool = false,
        playerLeds: Bool = false,
        triggerEffects: Bool = false,
        speaker: Bool = false,
        hapticLanes: Bool = false,
        mic: Bool = false
    ) {
        self.rumble = rumble
        self.triggerRumble = triggerRumble
        self.lightbar = lightbar
        self.playerLeds = playerLeds
        self.triggerEffects = triggerEffects
        self.speaker = speaker
        self.hapticLanes = hapticLanes
        self.mic = mic
    }
}

/// The bench's items, in the page's order. The stick tests read input
/// only, so every pad has them.
public enum BenchItem: CaseIterable, Equatable, Sendable {
    case rumble
    case triggerRumble
    case lightbar
    case playerLeds
    case adaptiveTriggers
    case speaker
    case haptics
    case microphone
}

/// The items a pad's path carries; an item it cannot carry is absent.
public func benchItems(_ carriage: BenchCarriage) -> [BenchItem] {
    BenchItem.allCases.filter { benchCarries(carriage, $0) }
}

func benchCarries(_ carriage: BenchCarriage, _ item: BenchItem) -> Bool {
    switch item {
    case .rumble: carriage.rumble
    case .triggerRumble: carriage.triggerRumble
    case .lightbar: carriage.lightbar
    case .playerLeds: carriage.playerLeds
    case .adaptiveTriggers: carriage.triggerEffects
    case .speaker: carriage.speaker
    case .haptics: carriage.hapticLanes
    case .microphone: carriage.mic
    }
}
