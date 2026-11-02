// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

/// Hands the newest object from the threads that post to the one thread that
/// reads it, without a lock. A post replaces, and releases, an object the
/// reader has not taken; a take moves the newest one out, so each object is
/// owned by the slot or by the reader and never by both. The reader's check
/// for mail is one relaxed load.
final class Mailbox<Value: AnyObject> {
    private let slot = AtomicWord.allocate()

    deinit {
        release(slot.exchange(0))
        slot.deallocate()
    }

    /// True when the box was empty, so nothing the reader had not taken was
    /// replaced.
    @discardableResult
    func post(_ value: Value) -> Bool {
        let bits = Int64(Int(bitPattern: Unmanaged.passRetained(value).toOpaque()))
        let replaced = slot.exchange(bits)
        release(replaced)
        return replaced == 0
    }

    var hasMail: Bool {
        slot.loadRelaxed() != 0
    }

    /// The newest object posted since the last take, or nil.
    func take() -> Value? {
        guard hasMail, let raw = UnsafeRawPointer(bitPattern: Int(slot.exchange(0))) else { return nil }
        return Unmanaged<Value>.fromOpaque(raw).takeRetainedValue()
    }

    private func release(_ bits: Int64) {
        guard let raw = UnsafeRawPointer(bitPattern: Int(bits)) else { return }
        Unmanaged<Value>.fromOpaque(raw).release()
    }
}
