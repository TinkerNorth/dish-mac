// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The report-descriptor walk behind `HidGamepadLayout`, ported from the
// desktops' `parseReportDescriptor`: Generic Desktop X/Y the left stick,
// Z/Rz the right, Rx/Ry the triggers, 0x39 the hat; Simulation Brake and
// Accelerator the triggers; the first Button field, up to 16. It runs once
// per attach, so it may allocate; the per-report decode does not. The bit
// arithmetic wraps like the desktops' unsigned 32-bit words, so a hostile
// descriptor misparses instead of trapping.

import Foundation

enum HidItemKind {
    case main
    case global
    case local
    case reserved

    /// Bits 3..2 of the prefix byte.
    static func of(_ prefix: UInt8) -> HidItemKind {
        switch (prefix >> 2) & 0x03 {
        case 0: .main
        case 1: .global
        case 2: .local
        default: .reserved
        }
    }
}

/// One short item of the descriptor stream.
struct HidItem: Equatable {
    let kind: HidItemKind
    let tag: UInt8
    let dataLength: UInt8
    let data: UInt32
}

enum HidReadStep: Equatable {
    case item(HidItem)
    /// A long item, which no gamepad descriptor uses, stepped over whole.
    case skipped
    /// The stream ended mid-item.
    case truncated
}

enum HidTag {
    static let longItemPrefix: UInt8 = 0xFE
    static let input: UInt8 = 0x8
    static let usagePage: UInt8 = 0x0
    static let logicalMinimum: UInt8 = 0x1
    static let logicalMaximum: UInt8 = 0x2
    static let reportSize: UInt8 = 0x7
    static let reportId: UInt8 = 0x8
    static let reportCount: UInt8 = 0x9
    static let usage: UInt8 = 0x0
    static let usageMinimum: UInt8 = 0x1
    static let usageMaximum: UInt8 = 0x2
    static let constantFlag: UInt32 = 0x01
    static let fourByteSizeCode: UInt8 = 3
}

enum HidUsagePage {
    static let genericDesktop: UInt32 = 0x01
    static let simulation: UInt32 = 0x02
    static let button: UInt32 = 0x09
}

enum HidParseLimits {
    static let maxUsages = 16
    static let maxButtons: UInt32 = 16
    /// Past this many fields in one item no further usage can name an axis:
    /// a range stops at the hat (0x39) and a list repeats its last usage.
    static let maxAxisFields: UInt32 = 64
}

/// What a field of each usage becomes.
enum HidFieldRole {
    case lx, ly, rx, ry, lt, rt, hat
}

let hidFieldRoles: [UInt32: [UInt32: HidFieldRole]] = [
    HidUsagePage.genericDesktop: [0x30: .lx, 0x31: .ly, 0x32: .rx, 0x35: .ry, 0x33: .lt, 0x34: .rt, 0x39: .hat],
    HidUsagePage.simulation: [0xC5: .lt, 0xC4: .rt]
]

/// A short item packs its data length, kind and tag into the prefix byte;
/// size code 3 means four bytes.
func readHidItem(_ descriptor: [UInt8], at index: inout Int) -> HidReadStep {
    let prefix = descriptor[index]
    index += 1
    guard prefix != HidTag.longItemPrefix else { return skipLongItem(descriptor, at: &index) }
    let sizeCode = prefix & 0x03
    let length = sizeCode == HidTag.fourByteSizeCode ? 4 : sizeCode
    guard index + Int(length) <= descriptor.count else { return .truncated }
    var data: UInt32 = 0
    for offset in 0 ..< Int(length) {
        data |= UInt32(descriptor[index + offset]) << (8 * UInt32(offset))
    }
    index += Int(length)
    return .item(HidItem(kind: HidItemKind.of(prefix), tag: (prefix >> 4) & 0x0F, dataLength: length, data: data))
}

/// A long item carries a payload-length byte, a tag byte, then the payload.
private func skipLongItem(_ descriptor: [UInt8], at index: inout Int) -> HidReadStep {
    guard index < descriptor.count else { return .truncated }
    index += 2 + Int(descriptor[index])
    return .skipped
}

func signExtend(_ value: UInt32, bytes: UInt8) -> Int32 {
    let fullWidth = bytes == 0 || bytes >= 4
    guard !fullWidth else { return Int32(bitPattern: value) }
    let bits = UInt32(bytes) * 8
    let signBit = UInt32(1) << (bits - 1)
    let negative = value & signBit != 0
    guard negative else { return Int32(bitPattern: value) }
    return Int32(bitPattern: value | ~((UInt32(1) << bits) - 1))
}

/// The Global and Local state the stream accumulates until a Main item
/// consumes it, and the layout it builds.
struct HidParseState {
    var usagePage: UInt32 = 0
    var reportSize: UInt32 = 0
    var reportCount: UInt32 = 0
    var logicalMin: Int32 = 0
    var logicalMax: Int32 = 0
    var currentReportId: UInt8 = 0
    var bitCursor: UInt32 = 0
    var lockedReportId: UInt8?
    var usages: [UInt32] = []
    var usageMin: UInt32 = 0
    var haveRange = false
    var layout = HidGamepadLayout()

    mutating func apply(_ item: HidItem) {
        switch item.kind {
        case .main: applyMain(item)
        case .global: applyGlobal(item)
        case .local: applyLocal(item)
        case .reserved: break
        }
    }

    /// Only an Input item carries fields this parse wants; every Main item
    /// clears the Local state.
    private mutating func applyMain(_ item: HidItem) {
        if item.tag == HidTag.input { applyInput(item) }
        usages = []
        haveRange = false
        usageMin = 0
    }

    /// A report id resets the bit cursor: offsets are relative to the payload
    /// of the report they are in. The maximum is read the way Linux hid-core
    /// reads it: signed only when the minimum before it is negative.
    private mutating func applyGlobal(_ item: HidItem) {
        switch item.tag {
        case HidTag.usagePage: usagePage = item.data
        case HidTag.logicalMinimum: logicalMin = signExtend(item.data, bytes: item.dataLength)
        case HidTag.logicalMaximum:
            logicalMax = logicalMin < 0 ? signExtend(item.data, bytes: item.dataLength) : Int32(bitPattern: item.data)
        case HidTag.reportSize: reportSize = item.data
        case HidTag.reportId:
            currentReportId = UInt8(truncatingIfNeeded: item.data)
            bitCursor = 0
        case HidTag.reportCount: reportCount = item.data
        default: break
        }
    }

    /// A usage minimum implies the range; a maximum only confirms it, since
    /// the count comes from the report count either way.
    private mutating func applyLocal(_ item: HidItem) {
        switch item.tag {
        case HidTag.usage:
            if usages.count < HidParseLimits.maxUsages { usages.append(item.data) }
        case HidTag.usageMinimum:
            usageMin = item.data
            haveRange = true
        case HidTag.usageMaximum: haveRange = true
        default: break
        }
    }

    /// Constant padding carries no field but still moves the cursor. The
    /// first report that carries fields locks the layout: a device with
    /// several input reports is described by the one this parse decodes.
    private mutating func applyInput(_ item: HidItem) {
        let startBit = bitCursor
        bitCursor = bitCursor &+ reportSize &* reportCount
        let isConstant = item.data & HidTag.constantFlag != 0
        let carriesFields = reportSize > 0 && reportCount > 0
        guard !isConstant, carriesFields else { return }
        let locked = lockedReportId ?? currentReportId
        lockedReportId = locked
        layout.reportId = locked
        guard currentReportId == locked else { return }
        if usagePage == HidUsagePage.button { takeButtons(startBit) }
        if let roles = hidFieldRoles[usagePage] { takeFields(startBit, roles: roles) }
    }

    /// The first button field wins: the layout carries one run.
    private mutating func takeButtons(_ startBit: UInt32) {
        guard layout.buttonCount == 0 else { return }
        layout.buttonBitOffset = UInt16(truncatingIfNeeded: startBit)
        layout.buttonCount = UInt8(min(reportCount, HidParseLimits.maxButtons))
    }

    /// One usage per field, counted up from the range's minimum or taken from
    /// the list, whose last entry repeats when the item declares more fields.
    private mutating func takeFields(_ startBit: UInt32, roles: [UInt32: HidFieldRole]) {
        let fields = min(reportCount, HidParseLimits.maxAxisFields)
        for index in 0 ..< fields {
            guard let usage = usage(at: index) else { return }
            guard let role = roles[usage] else { continue }
            let field = HidField(
                bitOffset: UInt16(truncatingIfNeeded: startBit &+ index &* reportSize),
                bitSize: UInt8(truncatingIfNeeded: reportSize),
                logicalMin: logicalMin,
                logicalMax: logicalMax
            )
            claim(role, field)
        }
    }

    private func usage(at index: UInt32) -> UInt32? {
        if haveRange { return usageMin &+ index }
        guard let last = usages.last else { return nil }
        return index < usages.count ? usages[Int(index)] : last
    }

    /// The first declaration of each role wins.
    private mutating func claim(_ role: HidFieldRole, _ field: HidField) {
        switch role {
        case .lx: layout.lx = layout.lx ?? field
        case .ly: layout.ly = layout.ly ?? field
        case .rx: layout.rx = layout.rx ?? field
        case .ry: layout.ry = layout.ry ?? field
        case .lt: layout.lt = layout.lt ?? field
        case .rt: layout.rt = layout.rt ?? field
        case .hat: layout.hat = layout.hat ?? field
        }
    }
}

public extension HidGamepadLayout {
    /// The field map a descriptor declares, read in `order`; nil on a
    /// descriptor with nothing gamepad-like in it. A truncated stream is read
    /// up to the cut.
    static func parse(descriptor: [UInt8], order: HidButtonOrder = .western) -> HidGamepadLayout? {
        var state = HidParseState()
        var index = 0
        readLoop: while index < descriptor.count {
            switch readHidItem(descriptor, at: &index) {
            case let .item(item): state.apply(item)
            case .skipped: continue
            case .truncated: break readLoop
            }
        }
        var layout = state.layout
        layout.order = order
        return layout.isGamepadLike ? layout : nil
    }
}
