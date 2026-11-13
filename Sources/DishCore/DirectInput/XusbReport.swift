// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// An Xbox 360 (XUSB) pad's vendor interface, read over USB because macOS
// gives it no HID device: the input report and the rumble report as
// dish-android's XINPUT_360 parser reads and builds them (SDL's
// `SDL_hidapi_xbox360.c` and Linux's `xpad360_process_packet` agree on the
// layout), and the endpoints they ride.

import Foundation

/// The vendor interface a wired 360 pad's input rides, as Linux's xpad and
/// SDL's libusb backend match it.
public enum XusbInterface {
    public static let interfaceClass = 0xFF
    public static let subclass = 0x5D
    public static let wiredProtocol = 0x01
}

public func isXusbInterface(interfaceClass: Int?, subclass: Int?, interfaceProtocol: Int?) -> Bool {
    let vendorClass = interfaceClass == XusbInterface.interfaceClass
    let xusb = subclass == XusbInterface.subclass
    let wired = interfaceProtocol == XusbInterface.wiredProtocol
    return vendorClass && xusb && wired
}

/// Report 0x00: its length byte, the XUSB button word, the two triggers and
/// the four sticks, little-endian and up-positive, as the wire has them.
private enum XusbLayout {
    static let inputType: UInt8 = 0x00
    static let sticksEnd = 14
    static let buttons = 2
    static let leftTrigger = 4
    static let rightTrigger = 5
    static let leftX = 6
    static let leftY = 8
    static let rightX = 10
    static let rightY = 12
}

/// Every button a 360 pad has: the word's one unassigned bit is the wire's
/// mic-mute, which no 360 pad presses.
private let xusbPadButtons = ~WireButton.micMute.bit

/// Nil for every other report the pad sends (its LED and rumble status) and
/// for one too short to hold the sticks.
public func decodeXusbReport(_ report: UnsafeBufferPointer<UInt8>) -> GamepadReport? {
    guard report.count >= XusbLayout.sticksEnd, report[0] == XusbLayout.inputType else { return nil }
    let buttons = xusbWord(report, XusbLayout.buttons) & xusbPadButtons
    return GamepadReport(
        buttons: buttons,
        lt: report[XusbLayout.leftTrigger],
        rt: report[XusbLayout.rightTrigger],
        lx: Int16(bitPattern: xusbWord(report, XusbLayout.leftX)),
        ly: Int16(bitPattern: xusbWord(report, XusbLayout.leftY)),
        rx: Int16(bitPattern: xusbWord(report, XusbLayout.rightX)),
        ry: Int16(bitPattern: xusbWord(report, XusbLayout.rightY))
    )
}

/// Two bytes as one little-endian word, read one by one so a report builds
/// nothing.
private func xusbWord(_ report: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt16 {
    UInt16(report[offset]) | UInt16(report[offset + 1]) << 8
}

// MARK: - Rumble

/// The large (low-frequency) motor's level, then the small one's, each the
/// wire level's high byte.
public func xusbRumbleReport(strong: UInt16, weak: UInt16) -> [UInt8] {
    [0x00, 0x08, 0x00, UInt8(truncatingIfNeeded: strong >> 8), UInt8(truncatingIfNeeded: weak >> 8), 0x00, 0x00, 0x00]
}

public let xusbRumbleStop = xusbRumbleReport(strong: 0, weak: 0)

/// A host command as an XUSB pad takes it: the pad holds a level until it
/// is sent another, so Dish sends the stop itself once the hold ends.
public struct XusbRumbleCommand: Equatable, Sendable {
    public let report: [UInt8]
    /// Nil for a stop.
    public let holdMs: Int64?
}

public func xusbRumbleCommand(strong: UInt16, weak: UInt16, durationMs: UInt16) -> XusbRumbleCommand {
    let still = strong == 0 && weak == 0
    let report = xusbRumbleReport(strong: strong, weak: weak)
    return XusbRumbleCommand(report: report, holdMs: still ? nil : directRumbleHoldMs(durationMs))
}

// MARK: - The interface's endpoints

/// One endpoint as the interface's descriptors give it.
public struct UsbEndpoint: Equatable, Sendable {
    public let address: UInt8
    public let attributes: UInt8
    public let maxPacketSize: UInt16

    public init(address: UInt8, attributes: UInt8, maxPacketSize: UInt16) {
        self.address = address
        self.attributes = attributes
        self.maxPacketSize = maxPacketSize
    }

    var isInterrupt: Bool {
        attributes & UsbEndpointBits.transferTypeMask == UsbEndpointBits.interrupt
    }

    var isIn: Bool {
        address & UsbEndpointBits.directionIn != 0
    }
}

private enum UsbEndpointBits {
    static let directionIn: UInt8 = 0x80
    static let transferTypeMask: UInt8 = 0x03
    static let interrupt: UInt8 = 0x03
}

/// The pipes an XUSB interface is read and driven through.
public struct XusbEndpoints: Equatable, Sendable {
    public let input: UsbEndpoint
    /// Nil for a pad with nowhere to send its rumble.
    public let output: UsbEndpoint?

    public init(input: UsbEndpoint, output: UsbEndpoint?) {
        self.input = input
        self.output = output
    }
}

/// SDL's libusb rule: the interface's first interrupt IN endpoint carries
/// the reports and its first interrupt OUT endpoint the rumble.
public func xusbEndpoints(_ endpoints: [UsbEndpoint]) -> XusbEndpoints? {
    let interrupts = endpoints.filter(\.isInterrupt)
    guard let input = interrupts.first(where: \.isIn) else { return nil }
    let output = interrupts.first { !$0.isIn }
    return XusbEndpoints(input: input, output: output)
}
