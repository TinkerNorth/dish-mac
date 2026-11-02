// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
import DishCore
import Foundation

/// Encrypt + sendto, the heartbeat timer and the receive loop. Factored out
/// of the main `SatelliteClient` class for readability only — all state lives
/// in the single session instance. Framing/AEAD are pure DishCore
/// (`PacketCodec` / `SessionCrypto`); this file is the socket shell.
extension SatelliteClient {

    // MARK: - Encrypt + sendto

    /// Seal one inner frame and fire it at the satellite:
    ///
    ///     token(4 BE) | counter(4 BE) | ChaCha20-Poly1305(inner)
    ///     inner = msgType(2 BE) | msgLen(2 BE) | payload
    ///
    /// nonce = `up(0x00) | 0×7 | counter(4 BE)`, AAD = token — via
    /// `SessionCrypto.seal` with the per-direction counter starting at 1
    /// (contract §Crypto; gaps G1/G2). `encode` writes every one of the
    /// `payloadCount` bytes (the writers' tests hold each to that) into a
    /// stack buffer that already holds the inner header, so CryptoKit's
    /// sealed box is the send's only allocation. Non-blocking send: a full
    /// socket buffer under Wi-Fi power-save drops the datagram rather than
    /// stalling the GameController callback thread — every stream is
    /// loss-safe.
    func sendEncrypted(msgType: UInt16, payloadCount: Int, encode: (UnsafeMutableRawBufferPointer) -> Void) {
        let innerCount = ProtocolConstants.innerHeaderSize + payloadCount
        let datagramCount = ProtocolConstants.headerSize + innerCount + ProtocolConstants.authTagSize
        guard isOpen, datagramCount <= ProtocolConstants.udpDatagramMaxBytes else { return }
        withUnsafeTemporaryAllocation(byteCount: ProtocolConstants.udpDatagramMaxBytes, alignment: 16) { scratch in
            let datagram = UnsafeMutableRawBufferPointer(rebasing: scratch[..<datagramCount])
            let inner = UnsafeMutableRawBufferPointer(
                rebasing: datagram[ProtocolConstants.headerSize ..< ProtocolConstants.headerSize + innerCount]
            )
            PacketCodec.writeInnerHeader(msgType: msgType, payloadCount: payloadCount, into: inner)
            encode(UnsafeMutableRawBufferPointer(rebasing: inner[ProtocolConstants.innerHeaderSize...]))
            gate.hold { sealAndSend(datagram, innerCount: innerCount) }
        }
    }

    /// The caller holds the gate, from the counter's claim to the `sendto`,
    /// so the session's datagrams leave in counter order. The box is sealed
    /// over the inner frame where it lies.
    private func sealAndSend(_ datagram: UnsafeMutableRawBufferPointer, innerCount: Int) {
        let (fd, destination) = sendTarget()
        guard fd >= 0 else { return }
        let (generation, sequence) = claimSend()
        // A counter can never wrap (contract §Crypto): sealing two plaintexts
        // under one (key, nonce) would be catastrophic, so past 2^32 − 1 the
        // session goes SILENT instead and self-heals via re-PUT — in practice
        // the G4 proactive re-key fires at 0xF0000000, 268M packets earlier.
        guard sequence <= UInt64(UInt32.max) else { return }
        let counter = UInt32(sequence)
        let box = UnsafeMutableRawBufferPointer(rebasing: datagram[ProtocolConstants.headerSize...])
        guard let sealed = try? SessionCrypto.seal(
            UnsafeRawBufferPointer(rebasing: box[..<innerCount]),
            into: box,
            key: generation.key,
            direction: .up,
            counter: counter,
            token: generation.token
        ) else { return }
        PacketCodec.writeHeader(token: generation.token, counter: counter, into: datagram)
        var address = destination
        blockingRegion("satellite.sendto")
        // A refused send is a dropped datagram: every stream is loss-safe.
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                sendDatagram(
                    fd,
                    UnsafeRawPointer(datagram.baseAddress),
                    ProtocolConstants.headerSize + sealed,
                    MSG_DONTWAIT,
                    target,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
    }

    // MARK: - Heartbeat (timer, no busy-wait — gap G19)

    /// Start the 2 s heartbeat timer (contract §Liveness). First beat fires
    /// immediately so a fresh session proves the data path without waiting a
    /// full interval.
    func startHeartbeat() {
        if heartbeatRunning.get() { return }
        heartbeatRunning.set(true)
        missedAcks.set(0)
        connectionAlive.set(true)
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(Self.heartbeatIntervalMs),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeatTimer = timer
        timer.resume()
    }

    func stopHeartbeat() {
        heartbeatRunning.set(false)
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func heartbeatTick() {
        guard heartbeatRunning.get() else { return }
        sendEncrypted(msgType: ProtocolConstants.msgHeartbeat, payloadCount: 0) { _ in }
        // The RTT clock starts on this session's own stamp. armPing keeps an
        // in-flight ping's clock (overwriting would pair a late ack with the
        // newer stamp and read artificially low) and reclaims past the 5 s
        // loss cap — the rule lives in DishCore.LatencyWindow (gap G13).
        armLatencyPing(nowMs: Self.monotonicNowMs())
        if missedAcks.incrementAndGet() >= Self.heartbeatMissMax {
            connectionAlive.set(false)
        }
    }

    // MARK: - Receive loop

    func startReceiveLoop() {
        if ackRunning.get() { return }
        ackRunning.set(true)
        let drained = receiveDrained
        drained.enter()
        ackQueue.async { [weak self] in
            defer { drained.leave() }
            while let self, self.ackRunning.get() {
                self.receiveOne()
            }
        }
    }

    /// Stop the loop and JOIN it (bounded by the 500 ms recv timeout) so the
    /// fd can close without racing a blocked `recvfrom` onto a reused fd.
    func stopReceiveLoop() {
        if !ackRunning.get() { return }
        ackRunning.set(false)
        blockingRegion("satellite.receiveJoin")
        _ = receiveDrained.wait(timeout: .now() + 1.0)
    }

    /// One datagram into the loop's own buffer, at the contract's ceiling:
    /// `recvfrom` truncates to the buffer, and a truncated audio ciphertext
    /// fails the AEAD, so a shorter buffer drops every full-size speaker
    /// frame in silence.
    private func receiveOne() {
        let fd = receiveFd
        if fd < 0 { return }
        let buffer = receiveBuffer
        var from = sockaddr_in()
        var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
        blockingRegion("satellite.recvfrom")
        let bytesRead = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.recvfrom(fd, buffer.baseAddress, buffer.count, 0, sa, &fl)
            }
        }
        // <= 0 is the SO_RCVTIMEO tick (or a transient error): loop around and
        // re-check `ackRunning`.
        guard bytesRead > 0 else { return }
        processIncoming(UnsafeRawBufferPointer(rebasing: buffer[..<bytesRead]))
    }

    /// One whole datagram handed in as `Data`, as the tests hand them.
    func processIncoming(_ datagram: Data) {
        datagram.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in processIncoming(raw) }
    }

    /// One datagram where it lies: header read in place → token filter →
    /// replay guard (G3) → AEAD open of the box in place, bound to
    /// direction/counter/token (G1/G2) → inner dispatch on a slice of the
    /// plaintext. Every failure is a silent drop, like the sibling clients.
    func processIncoming(_ datagram: UnsafeRawBufferPointer) {
        guard let header = PacketCodec.parseHeader(datagram) else { return }
        if let fresh = generationMail.take() {
            receiveGeneration = fresh
            lastRecvCounter.set(0)
        }
        let session = receiveGeneration
        guard header.token == session.token else { return }

        // Replay guard (server→client): drop counter <= last DECRYPTED
        // counter; first packet exempt while the guard is 0. The guard only
        // advances after a successful open, so a forged header can't wedge
        // the stream (mirrors satellite_jni receiveAck).
        let lastRecv = UInt32(truncatingIfNeeded: lastRecvCounter.current())
        if lastRecv != 0, header.counter <= lastRecv { return }

        guard let plain = try? SessionCrypto.open(
            boxBytes: UnsafeRawBufferPointer(rebasing: datagram[ProtocolConstants.headerSize...]),
            key: session.key,
            direction: .down,
            counter: header.counter,
            token: session.token
        ) else { return }
        lastRecvCounter.set(UInt64(header.counter))

        guard let inner = PacketCodec.parseInnerInPlace(plain) else { return }
        dispatch(inner)
    }

    /// Route one decrypted inner message. Runs on the receive queue; handlers
    /// hop threads themselves if they need to.
    private func dispatch(_ inner: PacketCodec.InnerMessage) {
        refreshReceiveHandlers()
        switch inner.msgType {
        case ProtocolConstants.msgHeartbeatAck:
            // Pair the ack with the in-flight ping BEFORE the liveness flags
            // flip, so the RTT window and the alive tick agree on ordering.
            recordLatencyAck(nowMs: Self.monotonicNowMs())
            missedAcks.set(0)
            connectionAlive.set(true)
            // Enriched ack (backend/count/epoch/bitmap) → snapshot for the
            // reconcile poll. A short (pre-protocol-1) ack still counts for
            // liveness above, just not for reconcile (gap G9 parse side).
            if let ack = HeartbeatAck.parse(inner.payload) {
                storeHeartbeatAck(ack)
            }
        case ProtocolConstants.msgRumble:
            guard let rumble = RumbleCommand.parse(inner.payload) else { return }
            receiveHandlers.rumble?(rumble)
        case ProtocolConstants.msgLightbar:
            guard let lightbar = LightbarCommand.parse(inner.payload) else { return }
            receiveHandlers.lightbar?(lightbar)
        case ProtocolConstants.msgTriggerEffects:
            guard let effects = TriggerEffectsCommand.parse(inner.payload) else { return }
            receiveHandlers.triggerEffects?(effects)
        case ProtocolConstants.msgPlayerLeds:
            guard let leds = PlayerLedsCommand.parse(inner.payload) else { return }
            receiveHandlers.playerLeds?(leds)
        case ProtocolConstants.msgSpeakerAudio:
            guard let frame = AudioFrame.parse(inner.payload) else { return }
            receiveHandlers.speakerAudio?(frame)
        case ProtocolConstants.msgHapticAudio:
            guard let frame = AudioFrame.parse(inner.payload) else { return }
            receiveHandlers.hapticAudio?(frame)
        case ProtocolConstants.msgMicLed:
            guard let led = MicLedCommand.parse(inner.payload) else { return }
            receiveHandlers.micLed?(led)
        case ProtocolConstants.msgSessionClose:
            guard let byte = inner.payload.first else { return }
            // Latch the reason and mark dead NOW: the session is already gone
            // server-side, so the alive tick doesn't wait out the full
            // heartbeat death window (gap G10 parse side). Unknown FUTURE
            // reason bytes degrade to the transient default arm.
            sessionCloseReason.set(Int(byte))
            connectionAlive.set(false)
            receiveHandlers.sessionClose?(CloseReason(rawValue: byte) ?? .shutdown)
        default:
            break
        }
    }
}
