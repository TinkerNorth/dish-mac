// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What the Mac says of itself for the diagnostics bundle and the issue
// match: its model identifier ("Mac14,2"), its macOS version and its
// architecture. No serial, no name, nothing that tells one Mac from another
// of its kind.

import Darwin
import Foundation

package struct HostMachine: Equatable {
    package let model: String
    package let osMajor: Int
    package let osMinor: Int
    package let osPatch: Int
    package let arch: String

    package init(model: String, osMajor: Int, osMinor: Int, osPatch: Int = 0, arch: String) {
        self.model = model
        self.osMajor = osMajor
        self.osMinor = osMinor
        self.osPatch = osPatch
        self.arch = arch
    }

    package static func current() -> HostMachine {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HostMachine(
            model: sysctlString("hw.model") ?? "Mac",
            osMajor: version.majorVersion,
            osMinor: version.minorVersion,
            osPatch: version.patchVersion,
            arch: currentArch
        )
    }

    /// "macOS 26.1", or "macOS 26.1.2" with a patch.
    package var osName: String {
        let patch = osPatch == 0 ? "" : ".\(osPatch)"
        return "macOS \(osMajor).\(osMinor)\(patch)"
    }
}

#if arch(arm64)
private let currentArch = "arm64"
#else
private let currentArch = "x86_64"
#endif

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
}
