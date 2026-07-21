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
    /// (contract §Crypto; gaps G1/G2). Non-blocking send: a full socket
    /// buffer under Wi-Fi power-save drops the datagram rather than stalling
    /// the GameController callback thread — every stream is loss-safe.
    func sendEncrypted(msgType: UInt16, payload: Data) {
        guard isOpen else { return }
        // One lock hold draws key, token and sequence together — a re-key
        // swapping mid-send can never pair an old key with a fresh counter.
        let (key, token, sequence) = nextSendMaterial()
        // A counter can never wrap (contract §Crypto): sealing two plaintexts
        // under one (key, nonce) would be catastrophic, so past 2^32 − 1 the
        // session goes SILENT instead and self-heals via re-PUT — in practice
        // the G4 proactive re-key fires at 0xF0000000, 268M packets earlier.
        guard sequence <= UInt64(UInt32.max) else { return }
        let ctr = UInt32(sequence)
        let inner = PacketCodec.innerFrame(msgType: msgType, payload: payload)
        guard let box = try? SessionCrypto.seal(
            inner,
            key: key,
            direction: .up,
            counter: ctr,
            token: token
        ) else { return }
        let packet = PacketCodec.frame(token: token, counter: ctr, box: box)

        withSocketLocked { fd, sendDest in
            guard fd >= 0 else { return }
            packet.withUnsafeBytes { raw in
                var destCopy = sendDest
                _ = withUnsafePointer(to: &destCopy) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(
                            fd,
                            raw.baseAddress,
                            raw.count,
                            MSG_DONTWAIT,
                            sa,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
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
        sendEncrypted(msgType: ProtocolConstants.msgHeartbeat, payload: Data())
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
        _ = receiveDrained.wait(timeout: .now() + 1.0)
    }

    private func receiveOne() {
        let (fd, _) = socketSnapshot()
        if fd < 0 { return }
        var buf = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_in()
        var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bytesRead = buf.withUnsafeMutableBufferPointer { bp -> Int in
            withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(fd, bp.baseAddress, bp.count, 0, sa, &fl)
                }
            }
        }
        // <= 0 is the SO_RCVTIMEO tick (or a transient error): loop around and
        // re-check `ackRunning`.
        guard bytesRead > 0 else { return }
        processIncoming(Data(buf[0 ..< bytesRead]))
    }

    /// One datagram: header split (PacketCodec) → token filter → replay guard
    /// (G3) → AEAD open bound to direction/counter/token (G1/G2) → inner
    /// dispatch. Every failure is a silent drop, like the sibling clients.
    func processIncoming(_ datagram: Data) {
        guard let (header, box) = PacketCodec.parse(datagram) else { return }
        let session = params.get()
        guard header.token == session.token else { return }

        // Replay guard (server→client): drop counter <= last DECRYPTED
        // counter; first packet exempt while the guard is 0. The guard only
        // advances after a successful open, so a forged header can't wedge
        // the stream (mirrors satellite_jni receiveAck).
        let lastRecv = UInt32(truncatingIfNeeded: lastRecvCounter.current())
        if lastRecv != 0, header.counter <= lastRecv { return }

        guard let plain = try? SessionCrypto.open(
            box,
            key: session.key,
            direction: .down,
            counter: header.counter,
            token: session.token
        ) else { return }
        lastRecvCounter.set(UInt64(header.counter))

        guard let inner = PacketCodec.parseInner(plain) else { return }
        dispatch(inner)
    }

    /// Route one decrypted inner message. Runs on the receive queue; handlers
    /// hop threads themselves if they need to.
    private func dispatch(_ inner: PacketCodec.InnerMessage) {
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
            onRumble?(rumble)
        case ProtocolConstants.msgLightbar:
            guard let lightbar = LightbarCommand.parse(inner.payload) else { return }
            onLightbar?(lightbar)
        case ProtocolConstants.msgSessionClose:
            guard let byte = inner.payload.first else { return }
            // Latch the reason and mark dead NOW: the session is already gone
            // server-side, so the alive tick doesn't wait out the full
            // heartbeat death window (gap G10 parse side). Unknown FUTURE
            // reason bytes degrade to the transient default arm.
            sessionCloseReason.set(Int(byte))
            connectionAlive.set(false)
            onSessionClose?(CloseReason(rawValue: byte) ?? .shutdown)
        default:
            break
        }
    }
}
