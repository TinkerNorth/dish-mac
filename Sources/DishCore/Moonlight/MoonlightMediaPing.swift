// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The datagrams that keep a host's video and audio ports open while the
/// dish streams nothing on them: the `X-SS-Ping-Payload` the RTSP SETUP
/// named, verbatim, then a sequence the host ignores; or the four bytes the
/// wire always carried, for a host that named no payload. Anything between
/// five and nineteen bytes is dropped by hosts.
public enum MoonlightMediaPing {
    public static let payloadLength = 16
    public static let pingLength = 20
    public static let legacy = Data("PING".utf8)

    public static func ssPing(payload: String, sequence: UInt32) -> Data {
        var writer = ByteWriter(capacity: pingLength)
        let raw = Array(payload.utf8).prefix(payloadLength)
        writer.append(Data(raw))
        writer.append(Data(count: payloadLength - raw.count))
        writer.u32LE(sequence)
        return writer.data
    }

    /// Whether the payload the host named can key the modern ping at all.
    public static func usable(_ payload: String) -> Bool {
        !payload.isEmpty
    }
}
