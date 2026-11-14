// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The pads Dish reads itself, by USB identity. The Nintendo rows are Direct
// by model (macOS lists the N64 pad and delivers none of its input); the
// generic HID rows are the desktops' known models (`UsbReportParsers.h`
// `kKnownModels`), Direct when macOS cannot read them, as is the XUSB row,
// dish-android's (`usb_parsers.cpp` `kKnownDevices`). Joy-Cons and the
// charging grip stay with macOS. A layout is verified by vendor exactly as
// the desktops' `isKnownFastLaneModel` has it, and guessed otherwise.

import Foundation

/// When Dish reads a model rather than macOS.
public enum DirectRule: Equatable, Sendable {
    /// Whatever macOS does with it.
    case byModel
    /// Only when GameController does not support it.
    case whenMacOSCannot
    /// Only once the user picks Direct: reading it turns the pad's keyboard
    /// and mouse off, and no such pad has been run on this path yet.
    case optIn
}

public enum DirectDecoder: Equatable, Sendable {
    case switchReport(SwitchPadKind)
    case hidGamepad(HidButtonOrder)
    /// The 2015 Steam Controller's vendor packets.
    case steamController
    /// The 2015 Steam Controller's packets over Bluetooth LE, in segments.
    case steamControllerBle
    /// The 2026 Steam Controller's numbered reports.
    case steamTriton
    /// An Xbox 360 pad's input reports on its XUSB vendor interface, read
    /// over USB: macOS has no HID device for it.
    case xusb
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
    /// A wireless receiver: each of its interfaces carries one paired
    /// controller, connected or not.
    public let receiver: Bool

    public var layoutVerified: Bool {
        hidLayoutVerified(vendorId: vendorId)
    }

    public var hasMotion: Bool {
        switch decoder {
        case .switchReport(.pro), .steamController, .steamControllerBle, .steamTriton: true
        case .switchReport, .hidGamepad, .xusb: false
        }
    }

    /// Dish sends the pad's own rumble report, with no GameController behind
    /// it: the 2026 Steam Controller and the XUSB pads. The 2015 Steam
    /// Controller has trackpad voice coils and no motors.
    public var drivesItsOwnRumble: Bool {
        switch decoder {
        case .steamTriton, .xusb: true
        case .switchReport, .hidGamepad, .steamController, .steamControllerBle: false
        }
    }

    /// The decoder fills the protocol 4 extended-buttons word: the Steam
    /// Controllers' extras and the Switch Pro's Capture button.
    public var hasExtendedButtons: Bool {
        switch decoder {
        case .switchReport(.pro), .steamController, .steamControllerBle, .steamTriton: true
        case .switchReport, .hidGamepad, .xusb: false
        }
    }

    /// The trackpads the router lands by the slot's pick: the 2015 pad's
    /// right pad is its right stick by default, the 2026 pad has two beside
    /// a real right stick.
    public var trackpads: SteamTrackpads {
        switch decoder {
        case .steamController, .steamControllerBle: .rightStickByDefault
        case .steamTriton: .twoPads
        case .switchReport, .hidGamepad, .xusb: .none
        }
    }
}

public enum DirectVendor {
    public static let sony: UInt16 = 0x054C
    public static let nintendo: UInt16 = 0x057E
    public static let eightBitDo: UInt16 = 0x2DC8
    public static let pdp: UInt16 = 0x0E6F
    public static let valve: UInt16 = 0x28DE
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
        offersStandard: offersStandard,
        receiver: false
    )
}

/// Opt-in, because reading it reconfigures the pad and no such pad has been
/// run on this path here.
private func valveModel(_ productId: UInt16, _ name: String, _ decoder: DirectDecoder, receiver: Bool) -> DirectModel {
    DirectModel(
        vendorId: DirectVendor.valve,
        productId: productId,
        name: name,
        decoder: decoder,
        family: .other,
        rule: .optIn,
        gameControllerCarriesOutput: false,
        offersStandard: true,
        receiver: receiver
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
        offersStandard: true,
        receiver: false
    )
}

/// An Xbox 360 pad on its vendor interface: macOS has no driver for it, so
/// GameController never lists it and only Dish reads it.
private func xusbModel(_ vendorId: UInt16, _ productId: UInt16, _ name: String) -> DirectModel {
    DirectModel(
        vendorId: vendorId,
        productId: productId,
        name: name,
        decoder: .xusb,
        family: .other,
        rule: .whenMacOSCannot,
        gameControllerCarriesOutput: false,
        offersStandard: false,
        receiver: false
    )
}

/// The PDP Afterglow Wireless (0e6f:0186) is left out on purpose: its USB
/// port is charge-only and it speaks the Switch Pro protocol. A Steam
/// Controller over Bluetooth LE is a model of its own, by the identity SDL
/// gives it there.
public let directModels: [DirectModel] = [
    nintendoModel(0x2009, "Nintendo Switch Pro Controller", .pro, offersStandard: true),
    nintendoModel(0x2019, "Nintendo N64 Online Controller", .n64, offersStandard: false),
    nintendoModel(0x2017, "Nintendo SNES Online Controller", .snes, offersStandard: false),
    hidModel(DirectVendor.sony, 0x0CDA, "PlayStation Classic controller", .playStationClassic),
    hidModel(DirectVendor.eightBitDo, 0x3100, "8BitDo USB Wireless Adapter (D-input)", .eightBitDo),
    hidModel(DirectVendor.eightBitDo, 0x3105, "8BitDo USB Wireless Adapter 2 (D-input)", .eightBitDo),
    hidModel(DirectVendor.eightBitDo, 0x5006, "8BitDo M30 (D-input)", .eightBitDo),
    xusbModel(DirectVendor.eightBitDo, 0x310B, "8BitDo Ultimate 2 Wireless Controller"),
    hidModel(DirectVendor.pdp, 0x0180, "PDP Faceoff Wired Pro Controller (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0181, "PDP Faceoff Deluxe Wired Pro Controller (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0184, "PDP Faceoff Deluxe+ Audio Controller (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0185, "PDP Wired Fight Pad Pro (Switch)", .nintendoSwitch),
    hidModel(DirectVendor.pdp, 0x0187, "PDP Rock Candy Wired Controller (Switch)", .nintendoSwitch),
    valveModel(0x1102, "Valve Steam Controller", .steamController, receiver: false),
    valveModel(0x1142, "Valve Steam Controller (dongle)", .steamController, receiver: true),
    valveModel(0x1106, "Valve Steam Controller (Bluetooth)", .steamControllerBle, receiver: false),
    valveModel(0x1302, "Valve Steam Controller (2026)", .steamTriton, receiver: false),
    valveModel(0x1303, "Valve Steam Controller (2026, Bluetooth)", .steamTriton, receiver: false),
    valveModel(0x1304, "Valve Steam Controller (2026) Puck", .steamTriton, receiver: true),
    valveModel(0x1305, "Valve Steam Controller (2026) receiver", .steamTriton, receiver: true)
]

/// The 2015 pad's controller interfaces are its vendor-defined ones; its
/// keyboard and mouse ride their own.
private let steamVendorPage = 0xFF00
/// The 2026 receiver's slots (SDL's `HIDAPI_DriverSteamTriton_IsSupportedDevice`);
/// its stripped pogo-pin interface is one collection of vendor usage
/// FF00:0002 (Linux's `steam_is_valve_interface`).
private let tritonReceiverSlots = 2 ... 5
private let tritonPogoUsage = 0x0002

/// Whether one of a Valve device's HID interfaces carries a controller: the
/// 2015 pad's vendor interface, a pad's one device over Bluetooth LE (as SDL
/// takes any Bluetooth device of the model), the 2026 pad's one unified
/// interface, and a 2026 receiver's slots, never its pogo pins. An interface
/// whose number IOKit does not give is judged by its usage alone.
public func steamInterfaceCarriesController(_ model: DirectModel, usagePage: Int?, usage: Int?, interfaceNumber: Int?) -> Bool {
    switch model.decoder {
    case .steamController:
        return usagePage == steamVendorPage
    case .steamControllerBle:
        return true
    case .steamTriton:
        guard model.receiver else { return true }
        let pogoPins = usagePage == steamVendorPage && usage == tritonPogoUsage
        let slot = interfaceNumber.map(tritonReceiverSlots.contains) ?? true
        return slot && !pogoPins
    case .switchReport, .hidGamepad, .xusb:
        return false
    }
}

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
