// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Darwin
import Foundation

/// Encrypt + sendto, heartbeat loop, and ACK receive loop. Factored out of
/// the main `SatelliteClient` class for readability only — all state still
/// lives in the single session instance.
extension SatelliteClient {

    // MARK: - Encrypt + sendto

    func sendEncrypted(msgType: UInt16, payload: [UInt8]) {
        if sock < 0 { return }

        let payloadLen = UInt16(payload.count)
        let innerLen = 4 + Int(payloadLen)
        var inner = [UInt8](repeating: 0, count: innerLen)
        putBE16(msgType, into: &inner, at: 0)
        putBE16(payloadLen, into: &inner, at: 2)
        if payloadLen > 0 {
            for idx in 0 ..< Int(payloadLen) {
                inner[4 + idx] = payload[idx]
            }
        }

        let ctr = UInt32(counter.incrementAndGet() - 1)

        // Nonce: 12 bytes, big-endian counter left-padded with zeros.
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        putBE32(ctr, into: &nonceBytes, at: 8)

        guard let nonce = try? ChaChaPoly.Nonce(data: Data(nonceBytes)) else { return }

        // AAD = raw token; matches libsodium's `chacha20poly1305_ietf_encrypt`
        // with AAD=token used on Android and the server.
        guard let sealed = try? ChaChaPoly.seal(
            Data(inner),
            using: self.currentKey,
            nonce: nonce,
            authenticating: Data(self.token)
        ) else { return }

        // Packet: token(4) + counter(4) + ciphertext + 16-byte tag
        var packet = Data(capacity: 8 + sealed.ciphertext.count + sealed.tag.count)
        packet.append(contentsOf: self.token)
        var ctrBE = [UInt8](repeating: 0, count: 4)
        putBE32(ctr, into: &ctrBE, at: 0)
        packet.append(contentsOf: ctrBE)
        packet.append(sealed.ciphertext)
        packet.append(sealed.tag)

        sendLock.lock()
        defer { sendLock.unlock() }
        let sfd = sock
        if sfd < 0 { return }
        packet.withUnsafeBytes { raw in
            var destCopy = self.dest
            _ = withUnsafePointer(to: &destCopy) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(
                        sfd,
                        raw.baseAddress,
                        raw.count,
                        0,
                        sa,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    // MARK: - Heartbeat

    func startHeartbeat() {
        if heartbeatRunning { return }
        heartbeatRunning = true
        missedAcks = 0
        connectionAlive = true
        heartbeatQueue.async { [weak self] in self?.heartbeatLoop() }
    }

    func stopHeartbeat() {
        heartbeatRunning = false
    }

    private func heartbeatLoop() {
        while heartbeatRunning {
            sendEncrypted(msgType: 0x0002, payload: [])
            missedAcks += 1
            if missedAcks >= Self.heartbeatMissMax {
                connectionAlive = false
            }
            // Sleep in 100ms chunks so stopHeartbeat kicks in quickly.
            var slept: UInt32 = 0
            while heartbeatRunning, slept < Self.heartbeatIntervalMs {
                usleep(100_000)
                slept += 100
            }
        }
    }

    // MARK: - ACK receive loop

    func startReceiveLoop() {
        if ackRunning { return }
        ackRunning = true
        ackQueue.async { [weak self] in
            while let self, self.ackRunning {
                self.receiveOne()
            }
        }
    }

    private func receiveOne() {
        if sock < 0 { return }
        var buf = [UInt8](repeating: 0, count: 128)
        var from = sockaddr_in()
        var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bytesRead = buf.withUnsafeMutableBufferPointer { bp -> Int in
            withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(sock, bp.baseAddress, bp.count, 0, sa, &fl)
                }
            }
        }
        if bytesRead < 8 { return }
        // Token check.
        for idx in 0 ..< 4 where buf[idx] != token[idx] {
            return
        }

        let ctr = (UInt32(buf[4]) << 24) | (UInt32(buf[5]) << 16)
            | (UInt32(buf[6]) << 8) | UInt32(buf[7])
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        putBE32(ctr, into: &nonceBytes, at: 8)
        guard let nonce = try? ChaChaPoly.Nonce(data: Data(nonceBytes)) else { return }

        let cipherAndTag = Data(buf[8 ..< bytesRead])
        guard cipherAndTag.count >= 16 else { return }
        let tag = cipherAndTag.suffix(16)
        let cipher = cipherAndTag.prefix(cipherAndTag.count - 16)
        guard let sealed = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag),
              let plain = try? ChaChaPoly.open(
                  sealed,
                  using: self.currentKey,
                  authenticating: Data(self.token)
              ) else { return }

        guard plain.count >= 4 else { return }
        let msgType = (UInt16(plain[0]) << 8) | UInt16(plain[1])
        let msgLen = (UInt16(plain[2]) << 8) | UInt16(plain[3])

        if msgType == 0x0003 { // MSG_HEARTBEAT_ACK
            missedAcks = 0
            connectionAlive = true
        } else if msgType == 0x0006, msgLen >= 4, plain.count >= 8 {
            let reqType = (UInt16(plain[4]) << 8) | UInt16(plain[5])
            let idx = plain[6]
            let result = plain[7]
            lastControllerAck = (Int32(reqType) << 16) | (Int32(idx) << 8) | Int32(result)
        } else if msgType == 0x0007, msgLen >= 2, plain.count >= 6 {
            vigemAvailable = Int8(plain[4] == 0 ? 0 : 1)
            activeControllerCount = Int8(bitPattern: plain[5])
        }
    }
}
