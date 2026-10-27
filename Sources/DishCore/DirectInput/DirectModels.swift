// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The pads Dish reads itself, by USB identity. The Nintendo rows are Direct
// by model (macOS lists the N64 pad and delivers none of its input); the
// generic HID rows are the desktops' known models (`UsbReportParsers.h`
// `kKnownModels`), Direct when macOS cannot read them. Joy-Cons and the
// charging grip stay with macOS. A layout is verified by vendor exactly as
// the desktops' `isKnownFastLaneModel` has it, and guessed otherwise.

import Foundation

/// When Dish reads a model rather than macOS.
public enum DirectRule: Equatable, Sendable {
    /// Whatever macOS does with it.
    case byModel
    /// Only when GameController does not support it.
    case whenMacOSCannot
}

public enum DirectDecoder: Equatable, Sendable {
    case switchReport(SwitchPadKind)
    case hidGamepad(HidButtonOrder)
}

/// The family a Direct pad is shown and emulated as.
public enum DirectFamily: Equatable, Sendable {
    case nintendo
    case other
}

public struct DirectModel: Equatable, Sendable {
    public let vendorId: UInt16
    public let productId: UInt16
    public let name: String
    public let decoder: DirectDecoder
    public let family: DirectFamily
    public let rule: DirectRule
    /// GameController may carry its rumble and player lights while Dish
    /// reads its input, when the pairing of the two is unambiguous.
    public let gameControllerCarriesOutput: Bool
    /// The user may send it back to GameController: only where both paths
    /// work. Never the N64, whose input GameController drops.
    public let offersStandard: Bool

    public var layoutVerified: Bool {
        hidLayoutVerified(vendorId: vendorId)
    }

    public var hasMotion: Bool {
        decoder == .switchReport(.pro)
    }
}

public enum DirectVendor {
    public static let sony: UInt16 = 0x054C
    public static let nintendo: UInt16 = 0x057E
    public static let eightBitDo: UInt16 = 0x2DC8
    public static let pdp: UInt16 = 0x0E6F
}

private func nintendoModel(_ productId: UInt16, _ name: String, _ kind: SwitchPadKind, offersStandard: Bool) -> DirectModel {
    DirectModel(
        vendorId: DirectVendor.nintendo,
        productId: productId,
        name: name,
        decoder: .switchReport(kind),
        family: .nintendo,
        rule: .byModel,
        gameControllerCarriesOutput: true,
        offersStandard: offersStandard
    )
}

private func hidModel(_ vendorId: UInt16, _ productId: UInt16, _ name: String, _ order: HidButtonOrder) -> DirectModel {
    DirectModel(
        vendorId: vendorId,
        productId: productId,
        name: name,
        decoder: .hidGamepad(order),
        family: .other,
        rule: .whenMacOSCannot,
        gameControllerCarriesOutput: false,
        offersStandard: true
    )
}

/// The PDP Afterglow Wireless (0e6f:0186) is left out on purpose: its USB
/// port is charge-only and it speaks the Switch Pro protocol.
public let directModels: [DirectModel] = [
    nintendoModel(0x2009, "Nintendo Switch Pro Controller", .pro, offersStandard: true),
    nintendoModel(0x2019, "Nintendo N64 Online Controller", .n64, offersStandard: false),
    nintendoModel(0x2017, "Nintendo SNES Online Controller", .snes, offersStandard: false),
    hidModel(DirectVendor.sony, 0x0CDA, "PlayStation Classic controller", .playStationClassic),
    hidModel(DirectVendor.eightBitDo, 0x3100, "8BitDo USB Wireless Adapter (D-input)", .eightBitDo),
    hidModel(DirectVendor.eightBitDo, 0x3105, "8BitDo USB Wireless Adapter 2 (D-input)", .eightBitDo),
    hidModel(DirectVendor.eightBitDo, 0x5006, "8BitDo M30 (D-input)", .eightBitDo),
    hidModel(DirectVendor.pdp, 0x0180, "PDP Faceoff Wired Pro Controller (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0181, "PDP Faceoff Deluxe Wired Pro Controller (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0184, "PDP Faceoff Deluxe+ Audio Controller (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0185, "PDP Wired Fight Pad Pro (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0187, "PDP Rock Candy Wired Controller (Switch)", .nintendoSwitch)
]

public func directModel(vendorId: UInt16, productId: UInt16) -> DirectModel? {
    directModels.first { $0.vendorId == vendorId && $0.productId == productId }
}

private let verifiedHidVendors: Set<UInt16> = [DirectVendor.sony, DirectVendor.nintendo, DirectVendor.eightBitDo]

/// The desktops' verified lane, by vendor; any other pad's layout is guessed.
public func hidLayoutVerified(vendorId: UInt16) -> Bool {
    verifiedHidVendors.contains(vendorId)
}

/// The order a generic HID pad is read in: its model's, or DirectInput's.
public func hidButtonOrder(vendorId: UInt16, productId: UInt16) -> HidButtonOrder {
    guard case let .hidGamepad(order) = directModel(vendorId: vendorId, productId: productId)?.decoder else { return .western }
    return order
}

private struct CategoryMarker {
    let marker: String
    let productId: UInt16
}

/// GameController's product category for each Direct-by-model pad: "Switch
/// Pro Controller", "Switch N64 Controller" and the SNES pad's.
private let gameControllerCategoryMarkers = [
    CategoryMarker(marker: "switch pro", productId: 0x2009),
    CategoryMarker(marker: "n64", productId: 0x2019),
    CategoryMarker(marker: "snes", productId: 0x2017)
]

/// The Direct-by-model pad a GameController product category names, so that
/// controller gets no input slot of its own.
public func directModel(gameControllerCategory category: String) -> DirectModel? {
    let words = category.lowercased()
    let named = gameControllerCategoryMarkers.first { words.contains($0.marker) }
    return named.flatMap { directModel(vendorId: DirectVendor.nintendo, productId: $0.productId) }
}

/// The fleet's `usb_path_choices` key: "vvvv:pppp" in lowercase hex.
public func usbPathKey(vendorId: UInt16, productId: UInt16) -> String {
    String(format: "%04x:%04x", UInt32(vendorId), UInt32(productId))
}
