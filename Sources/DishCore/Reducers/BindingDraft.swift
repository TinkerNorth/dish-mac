// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Configure binding page's draft, the desktops' BindingDraft: every
// answer the page takes lands here and nothing is written until the one
// apply. The page opened with `original`; `current` is what it would apply.

import Foundation

/// Where a pad goes and what it carries there: the destination, the type it
/// is emulated as (nil is Auto), and the controller's own switches. The
/// defaults are the fleet's for a controller never switched.
public struct BindingChoice: Equatable, Sendable {
    public var connectionId: String?
    public var emulatedType: Int?
    public var motion: Bool
    public var rumble: Bool
    public var touchpad: TouchpadPick
    public var mic: Bool
    public var speaker: Bool

    public init(
        connectionId: String? = nil,
        emulatedType: Int? = nil,
        motion: Bool = true,
        rumble: Bool = true,
        touchpad: TouchpadPick = .pad,
        mic: Bool = false,
        speaker: Bool = true
    ) {
        self.connectionId = connectionId
        self.emulatedType = emulatedType
        self.motion = motion
        self.rumble = rumble
        self.touchpad = touchpad
        self.mic = mic
        self.speaker = speaker
    }
}

public struct BindingDraft: Equatable, Sendable {
    public let slotId: String
    public internal(set) var original: BindingChoice
    public internal(set) var current: BindingChoice

    public init(slotId: String, original: BindingChoice) {
        self.slotId = slotId
        self.original = original
        current = original
    }
}

public enum BindingDraftEvent: Equatable, Sendable {
    case chooseDestination(String)
    case chooseType(Int?)
    case setMotion(Bool)
    case setRumble(Bool)
    case setTouchpad(TouchpadPick)
    case setMic(Bool)
    case setSpeaker(Bool)
    /// Back to what the page opened with.
    case reset
    /// The apply landed: what was applied is the new baseline.
    case applied
}

/// One edit of the draft. Another destination is another catalog, so the
/// type starts over at Auto; the same destination keeps it.
public func reduce(_ draft: BindingDraft, _ event: BindingDraftEvent) -> BindingDraft {
    var next = draft
    switch event {
    case let .chooseDestination(id): next.current = chosen(draft.current, destination: id)
    case let .chooseType(type): next.current.emulatedType = type
    case let .setMotion(on): next.current.motion = on
    case let .setRumble(on): next.current.rumble = on
    case let .setTouchpad(pick): next.current.touchpad = pick
    case let .setMic(on): next.current.mic = on
    case let .setSpeaker(on): next.current.speaker = on
    case .reset: next.current = draft.original
    case .applied: next.original = draft.current
    }
    return next
}

private func chosen(_ choice: BindingChoice, destination id: String) -> BindingChoice {
    guard choice.connectionId != id else { return choice }
    var next = choice
    next.connectionId = id
    next.emulatedType = nil
    return next
}

/// The draft differs from what the page opened with: leaving asks first.
public func isDirty(_ draft: BindingDraft) -> Bool {
    draft.current != draft.original
}

/// A draft that names a destination can be applied, changed or not: a
/// second apply sends the binding again.
public func canApply(_ draft: BindingDraft) -> Bool {
    draft.current.connectionId != nil
}
