// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import dnssd
import Foundation

/// A Bonjour service registered on behalf of a host that does not exist,
/// whose name carries both an A and an AAAA record, published from one
/// registrant so neither displaces the other: the dual-stack host every
/// Windows machine is, on the loopback addresses so any Mac can stand it
/// up. A resolver that takes whichever address answers first lands on `::1`;
/// the browse under test must hand back `127.0.0.1`.
final class ProxiedDualStackHost {
    static let ipv4 = "127.0.0.1"
    static let ipv6 = "::1"
    private static let port: UInt16 = 9
    private static let ttl: UInt32 = 120
    /// The service and its two address records each confirm once.
    private static let confirmations = 3

    /// The service type, with the trailing dot `NWBrowser` wants.
    let serviceType: String
    let hostName: String
    private let replies = Replies()
    private let queue = DispatchQueue(label: "dish.test.proxied-host")
    private var service: DNSServiceRef?
    private var records: DNSServiceRef?

    struct Failure: Error {
        let step: String
        let code: DNSServiceErrorType
    }

    init() throws {
        let suffix = UInt32.random(in: 1000 ... 9999)
        let type = "_dish\(suffix)._udp"
        serviceType = type + "."
        hostName = "dish-dual-\(suffix).local."
        let context = Unmanaged.passUnretained(replies).toOpaque()
        var service: DNSServiceRef?
        try Self.check(
            DNSServiceRegister(
                &service, 0, 0, "probe", type, nil, hostName, Self.port.bigEndian, 0, nil, Self.serviceReply, context
            ),
            "register the service"
        )
        self.service = service
        var records: DNSServiceRef?
        try Self.check(DNSServiceCreateConnection(&records), "open the record connection")
        self.records = records
        var a4 = in_addr()
        _ = inet_pton(AF_INET, Self.ipv4, &a4)
        try withUnsafeBytes(of: &a4) { try register(rrtype: kDNSServiceType_A, rdata: $0, context: context) }
        var a6 = in6_addr()
        _ = inet_pton(AF_INET6, Self.ipv6, &a6)
        try withUnsafeBytes(of: &a6) { try register(rrtype: kDNSServiceType_AAAA, rdata: $0, context: context) }
        DNSServiceSetDispatchQueue(service, queue)
        DNSServiceSetDispatchQueue(records, queue)
    }

    /// True once the daemon has confirmed the service and both records, so a
    /// browse that follows resolves against records that are on the air.
    func advertised(within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if replies.confirmed >= Self.confirmations { return true }
            if replies.failed { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return replies.confirmed >= Self.confirmations
    }

    /// Takes the service and its records off the air.
    func stop() {
        if let records { DNSServiceRefDeallocate(records) }
        if let service { DNSServiceRefDeallocate(service) }
        records = nil
        service = nil
    }

    private func register(rrtype: Int, rdata: UnsafeRawBufferPointer, context: UnsafeMutableRawPointer) throws {
        var ref: DNSRecordRef?
        try Self.check(
            DNSServiceRegisterRecord(
                records,
                &ref,
                DNSServiceFlags(kDNSServiceFlagsUnique),
                0,
                hostName,
                UInt16(rrtype),
                UInt16(kDNSServiceClass_IN),
                UInt16(rdata.count),
                rdata.baseAddress,
                Self.ttl,
                Self.recordReply,
                context
            ),
            "register record type \(rrtype)"
        )
    }

    private static func check(_ code: DNSServiceErrorType, _ step: String) throws {
        if Int(code) != kDNSServiceErr_NoError { throw Failure(step: step, code: code) }
    }

    private static let serviceReply: DNSServiceRegisterReply = { _, _, errorCode, _, _, _, context in
        Replies.from(context)?.note(errorCode)
    }

    private static let recordReply: DNSServiceRegisterRecordReply = { _, _, _, errorCode, context in
        Replies.from(context)?.note(errorCode)
    }

    /// The daemon's confirmations, counted off its own queue.
    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var failure = false

        var confirmed: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        var failed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func note(_ errorCode: DNSServiceErrorType) {
            lock.lock()
            defer { lock.unlock() }
            if Int(errorCode) == kDNSServiceErr_NoError { count += 1 } else { failure = true }
        }

        static func from(_ context: UnsafeMutableRawPointer?) -> Replies? {
            guard let context else { return nil }
            return Unmanaged<Replies>.fromOpaque(context).takeUnretainedValue()
        }
    }
}
