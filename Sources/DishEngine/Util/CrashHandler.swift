// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Arms handlers for the fatal signals that carry a usable stack and appends a
// backtrace to the crash log. Nothing is transmitted anywhere; the file is
// the user's to send, redacted, through `CrashReport`.
//
// The handler must never recurse or allocate, so it uses only
// async-signal-safe calls over buffers filled at install, and re-raises on
// the default disposition afterwards so the system's own crash reporter and
// the shell still see the real signal.

import Darwin
import Foundation

/// The handler's fixed storage, filled once at install and only read from
/// the handler. A `let` holding buffers, not a mutable static: a C signal
/// handler takes no context, so this is the one place process-level state
/// is unavoidable, and the install step is its only writer.
private let crashHandlerStorage = CrashHandlerStorage()

final class CrashHandlerStorage: @unchecked Sendable {
    let path = UnsafeMutablePointer<CChar>.allocate(capacity: CrashHandler.pathCapacity)
    let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: CrashHandler.maxFrames)
    /// Somewhere for SA_ONSTACK to run when the fault is a stack overflow.
    let alternateStack = UnsafeMutableRawPointer.allocate(byteCount: CrashHandler.alternateStackSize, alignment: 16)
    let installed = AtomicBool(false)
    let inHandler = AtomicBool(false)

    init() {
        path.initialize(repeating: 0, count: CrashHandler.pathCapacity)
        frames.initialize(repeating: nil, count: CrashHandler.maxFrames)
    }
}

package enum CrashHandler {
    static let pathCapacity = 1024
    static let maxFrames = 64
    static let alternateStackSize = 64 * 1024
    static let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL]

    /// Arms the handlers once per process and creates the log's directory;
    /// false when a prior call already armed them.
    @discardableResult
    package static func install(log: CrashLog) -> Bool {
        guard !crashHandlerStorage.installed.getAndSet(true) else { return false }
        try? FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = strlcpy(crashHandlerStorage.path, log.path, pathCapacity)
        armAlternateStack()
        for signal in signals {
            arm(signal)
        }
        return true
    }

    private static func armAlternateStack() {
        var stack = stack_t(ss_sp: crashHandlerStorage.alternateStack, ss_size: alternateStackSize, ss_flags: 0)
        _ = sigaltstack(&stack, nil)
    }

    private static func arm(_ signal: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = dishCrashHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_ONSTACK | SA_RESTART
        _ = sigaction(signal, &action, nil)
    }

    /// The signal's name with the newline the record ends on, static so the
    /// handler allocates nothing.
    static func signalName(_ signal: Int32) -> StaticString {
        if signal == SIGSEGV { return "SIGSEGV\n" }
        if signal == SIGABRT { return "SIGABRT\n" }
        if signal == SIGBUS { return "SIGBUS\n" }
        if signal == SIGFPE { return "SIGFPE\n" }
        if signal == SIGILL { return "SIGILL\n" }
        return "signal\n"
    }

    /// Fills the frame buffer with the current stack; the depth captured.
    static func captureFrames() -> Int32 {
        backtrace(crashHandlerStorage.frames, Int32(maxFrames))
    }

    /// One record: the marker, the signal and the captured frames.
    static func writeRecord(to fd: Int32, signal: Int32, depth: Int32) {
        writeAll(fd, "--- dish crash: ")
        writeAll(fd, signalName(signal))
        backtrace_symbols_fd(crashHandlerStorage.frames, depth, fd)
    }

    /// The whole text or nothing more: a short write is retried from where
    /// it stopped, an error ends the attempt.
    static func writeAll(_ fd: Int32, _ text: StaticString) {
        let count = text.utf8CodeUnitCount
        var written = 0
        while written < count {
            let step = write(fd, text.utf8Start + written, count - written)
            if step <= 0 { return }
            written += Int(step)
        }
    }

    /// The log path as installed, for the record the user is shown.
    static var installedPath: String? {
        crashHandlerStorage.installed.get() ? String(cString: crashHandlerStorage.path) : nil
    }
}

/// The handler proper. A fault inside it would otherwise loop until the
/// stack is gone, so a second entry exits at once with the signal's code.
private func dishCrashHandler(_ signal: Int32) {
    if crashHandlerStorage.inHandler.getAndSet(true) { _exit(128 + signal) }
    let depth = CrashHandler.captureFrames()
    CrashHandler.writeAll(STDERR_FILENO, "dish crashed: ")
    CrashHandler.writeAll(STDERR_FILENO, CrashHandler.signalName(signal))
    backtrace_symbols_fd(crashHandlerStorage.frames, depth, STDERR_FILENO)
    if crashHandlerStorage.path[0] != 0 {
        let fd = open(crashHandlerStorage.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if fd >= 0 {
            CrashHandler.writeRecord(to: fd, signal: signal, depth: depth)
            close(fd)
        }
    }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}
