// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The XUSB reader's bus in the app: IOKit's matching notifications on the
// reader's queue, and IOUSBHost to open what they find. A wired 360 pad's
// device is vendor-class, and no Apple driver configures one: the composite
// driver matches device classes 0 and 7 and the interface-association class
// only, and macOS's own XboxGamepad.dext gives each Microsoft pad a
// device-level personality of its own beside its interface one. So a
// vendor-class device's interfaces appear only once someone selects its
// configuration, and Dish selects the first one of a model it reads when
// none is selected. IOUSBHostInterface matching takes only the USB class
// specification's key combinations, so every interface is watched and the
// reader decides which it reads.

import DishCore
import Foundation
import IOKit
import IOUSBHost
import os

/// A device with no configuration selected publishes no interfaces.
func usbDeviceNeedsConfiguration(currentConfiguration: Int?) -> Bool {
    (currentConfiguration ?? 0) == 0
}

/// The XUSB models' devices by USB identity, a combination IOUSBHostDevice
/// matching takes.
func xusbDeviceIdentities() -> [[String: Int]] {
    directModels.filter { $0.decoder == .xusb }.map { model in
        [UsbInterfaceKey.vendorId: Int(model.vendorId), UsbInterfaceKey.productId: Int(model.productId)]
    }
}

/// The interface properties the reader decides on.
private let xusbInterfaceKeys = [
    UsbInterfaceKey.vendorId, UsbInterfaceKey.productId, UsbInterfaceKey.interfaceClass,
    UsbInterfaceKey.interfaceSubclass, UsbInterfaceKey.interfaceProtocol
]

final class IOUSBHostXusbBus: XusbBus, @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")

    // Touched only on the reader's queue.
    private var queue: DispatchQueue?
    private var events: XusbBusEvents?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init() {}

    /// The notifications end with the bus; it goes on the reader's queue, so
    /// no callback runs as it does.
    deinit {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        if let port { IONotificationPortDestroy(port) }
    }

    func start(queue: DispatchQueue, events: XusbBusEvents) {
        self.queue = queue
        self.events = events
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port
        for identity in xusbDeviceIdentities() {
            watch(matching(kIOUSBHostDeviceClassName, identity), kIOFirstMatchNotification, xusbDevicesMatched)
        }
        watch(matching(kIOUSBHostInterfaceClassName, [:]), kIOFirstMatchNotification, xusbInterfacesMatched)
        watch(matching(kIOUSBHostInterfaceClassName, [:]), kIOTerminatedNotification, xusbInterfacesTerminated)
    }

    /// Draining the iterator once arms the notification and hands over every
    /// service already there.
    private func watch(_ matching: CFDictionary, _ kind: String, _ callback: IOServiceMatchingCallback) {
        guard let port else { return }
        var iterator: io_iterator_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddMatchingNotification(port, kind, matching, callback, context, &iterator)
        guard status == KERN_SUCCESS else { return Self.log.error("XUSB watch failed kind=\(kind, privacy: .public) status=\(status)") }
        iterators.append(iterator)
        callback(context, iterator)
    }

    fileprivate func devicesMatched(_ iterator: io_iterator_t) {
        for service in drain(iterator) {
            configureIfNeeded(service)
            IOObjectRelease(service)
        }
    }

    fileprivate func interfacesMatched(_ iterator: io_iterator_t) {
        for service in drain(iterator) {
            let properties = registryProperties(service, keys: xusbInterfaceKeys)
            let port = IOUSBHostXusbPort(service)
            events?.arrived(XusbInterfaceArrival(registryId: registryId(of: service), properties: properties, port: port))
            IOObjectRelease(service)
        }
    }

    fileprivate func interfacesTerminated(_ iterator: io_iterator_t) {
        for service in drain(iterator) {
            events?.removed(registryId(of: service))
            IOObjectRelease(service)
        }
    }

    /// Opening the device holds it only while the configuration is selected;
    /// a device another client holds stays as it is.
    private func configureIfNeeded(_ service: io_service_t) {
        let current = registryValue(service, IOUSBHostDevicePropertyKey.currentConfiguration.rawValue) as? Int
        guard usbDeviceNeedsConfiguration(currentConfiguration: current), let queue else { return }
        blockingRegion("xusb.configure")
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: nil)
            defer { device.destroy() }
            let configuration = try device.configurationDescriptor(with: 0).pointee.bConfigurationValue
            try device.__configure(withValue: Int(configuration), matchInterfaces: true)
            Self.log.info("XUSB configured device=\(registryId(of: service)) configuration=\(configuration)")
        } catch {
            Self.log.error("XUSB configure refused device=\(registryId(of: service)) status=\(ioReturn(of: error))")
        }
    }
}

private func matching(_ className: String, _ keys: [String: Int]) -> CFDictionary {
    let dictionary = IOServiceMatching(className) as NSMutableDictionary
    dictionary.addEntries(from: keys)
    return dictionary
}

private func drain(_ iterator: io_iterator_t) -> [io_service_t] {
    Array(sequence(state: iterator) { iterator in
        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    })
}

private func registryValue(_ service: io_service_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

private func registryProperties(_ service: io_service_t, keys: [String]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: keys.compactMap { key in registryValue(service, key).map { (key, $0) } })
}

/// The identity every notification about one service shares.
private func registryId(of service: io_service_t) -> UInt64 {
    var registryId: UInt64 = 0
    let status = IORegistryEntryGetRegistryEntryID(service, &registryId)
    return status == KERN_SUCCESS ? registryId : UInt64(service)
}

private func xusbDevicesMatched(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let context else { return }
    Unmanaged<IOUSBHostXusbBus>.fromOpaque(context).takeUnretainedValue().devicesMatched(iterator)
}

private func xusbInterfacesMatched(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let context else { return }
    Unmanaged<IOUSBHostXusbBus>.fromOpaque(context).takeUnretainedValue().interfacesMatched(iterator)
}

private func xusbInterfacesTerminated(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let context else { return }
    Unmanaged<IOUSBHostXusbBus>.fromOpaque(context).takeUnretainedValue().interfacesTerminated(iterator)
}

// MARK: - One interface

final class IOUSBHostXusbPort: XusbPort {
    private let service: io_service_t

    init(_ service: io_service_t) {
        IOObjectRetain(service)
        self.service = service
    }

    deinit {
        IOObjectRelease(service)
    }

    /// IOUSBHost opens an interface for one client: another app's or a
    /// driver's hold refuses it.
    func open(queue: DispatchQueue) throws -> XusbOpenInterface {
        let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
        do {
            return try IOUSBHostXusbInterface(interface)
        } catch {
            interface.destroy()
            throw error
        }
    }
}

final class IOUSBHostXusbInterface: XusbOpenInterface {
    let input: UsbInputPipe
    let output: UsbOutputPipe?
    private let interface: IOUSBHostInterface
    private let inputPipe: IOUSBHostInputPipe

    init(_ interface: IOUSBHostInterface) throws {
        guard let endpoints = xusbEndpoints(interfaceEndpoints(interface)) else {
            throw NSError(domain: IOUSBHostErrorDomain, code: Int(kIOReturnNotFound))
        }
        let inputPipe = try IOUSBHostInputPipe(interface, endpoints.input)
        self.inputPipe = inputPipe
        input = inputPipe
        output = try endpoints.output.map { try IOUSBHostOutputPipe(interface, $0) }
        self.interface = interface
    }

    func close() {
        inputPipe.abort()
        interface.destroy()
    }
}

final class IOUSBHostInputPipe: UsbInputPipe {
    private let pipe: IOUSBHostPipe
    /// Memory the controller writes each report into, the pipe's for its life.
    private let data: NSMutableData
    private let bytes: UnsafeMutablePointer<UInt8>
    private let capacity: Int

    init(_ interface: IOUSBHostInterface, _ endpoint: UsbEndpoint) throws {
        pipe = try interface.copyPipe(withAddress: Int(endpoint.address))
        capacity = Int(endpoint.maxPacketSize)
        data = try interface.ioData(withCapacity: capacity)
        bytes = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
    }

    func received(_ length: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: bytes, count: min(length, capacity))
    }

    func read(_ completion: @escaping UsbReadCompletion) -> IOReturn {
        do {
            try pipe.enqueueIORequest(with: data, completionTimeout: 0, completionHandler: completion)
            return kIOReturnSuccess
        } catch {
            return ioReturn(of: error)
        }
    }

    /// The read in flight completes as aborted on the reader's queue, after
    /// this returns: a synchronous abort would wait on that queue.
    func abort() {
        do {
            try pipe.__abort(with: .asynchronous)
        } catch {
            IOUSBHostXusbBus.log.error("XUSB abort failed status=\(ioReturn(of: error))")
        }
    }
}

/// Written on the pad's output queue, which a write holds until the pad
/// takes the report.
final class IOUSBHostOutputPipe: UsbOutputPipe, @unchecked Sendable {
    private let pipe: IOUSBHostPipe

    init(_ interface: IOUSBHostInterface, _ endpoint: UsbEndpoint) throws {
        pipe = try interface.copyPipe(withAddress: Int(endpoint.address))
    }

    func write(_ bytes: [UInt8]) -> IOReturn {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        blockingRegion("xusb.write")
        do {
            try pipe.__sendIORequest(with: data, bytesTransferred: nil, completionTimeout: 0)
            return kIOReturnSuccess
        } catch {
            return ioReturn(of: error)
        }
    }
}

// MARK: - The interface's endpoints

/// The endpoint descriptors after one, within the interface's own.
private struct EndpointWalk {
    let configuration: UnsafePointer<IOUSBConfigurationDescriptor>
    let interface: UnsafePointer<IOUSBInterfaceDescriptor>

    func next(after current: UnsafeRawPointer) -> UnsafePointer<IOUSBEndpointDescriptor>? {
        IOUSBGetNextEndpointDescriptor(configuration, interface, current.assumingMemoryBound(to: IOUSBDescriptorHeader.self))
    }
}

/// The low 11 bits of `wMaxPacketSize` are the size; the rest count extra
/// transactions per microframe.
private let usbPacketSizeMask: UInt16 = 0x07FF

private func interfaceEndpoints(_ interface: IOUSBHostInterface) -> [UsbEndpoint] {
    let walk = EndpointWalk(configuration: interface.configurationDescriptor, interface: interface.interfaceDescriptor)
    guard let first = walk.next(after: UnsafeRawPointer(walk.interface)) else { return [] }
    return sequence(first: first) { walk.next(after: UnsafeRawPointer($0)) }.map(usbEndpoint)
}

private func usbEndpoint(_ descriptor: UnsafePointer<IOUSBEndpointDescriptor>) -> UsbEndpoint {
    let endpoint = descriptor.pointee
    let size = UInt16(littleEndian: endpoint.wMaxPacketSize) & usbPacketSizeMask
    return UsbEndpoint(address: endpoint.bEndpointAddress, attributes: endpoint.bmAttributes, maxPacketSize: size)
}
