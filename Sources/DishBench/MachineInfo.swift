// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import Foundation

/// The machine a run was measured on.
struct MachineInfo: Codable, Equatable {
    private static let bytesPerGigabyte = 1_073_741_824.0

    let model: String
    let cpu: String
    let cores: Int
    let memoryGB: Double
    let os: String

    static func current() -> MachineInfo {
        let info = ProcessInfo.processInfo
        let gigabytes = Double(info.physicalMemory) / bytesPerGigabyte
        return MachineInfo(
            model: sysctlString("hw.model"),
            cpu: sysctlString("machdep.cpu.brand_string"),
            cores: info.activeProcessorCount,
            memoryGB: (gigabytes * 10).rounded() / 10,
            os: info.operatingSystemVersionString
        )
    }
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}
