import XCTest
@testable import Dish

final class GamepadInputProcessorTests: XCTestCase {

    // MARK: - Axis scaling

    func testScaleAxisCenterIsZero() {
        XCTAssertEqual(scaleAxis(0, max: 32767), 0)
    }

    func testScaleAxisFullPositive() {
        XCTAssertEqual(scaleAxis(1, max: 32767), 32767)
    }

    func testScaleAxisFullNegative() {
        // -1.0 * 32767 = -32767 (Xbox convention, one short of -32768 floor).
        XCTAssertEqual(scaleAxis(-1, max: 32767), -32767)
    }

    func testScaleAxisClampsOverflow() {
        XCTAssertEqual(scaleAxis(2, max: 32767), Int16.max)
        XCTAssertEqual(scaleAxis(-2, max: 32767), Int16.min)
    }

    // MARK: - Trigger scaling

    func testScaleTriggerBounds() {
        XCTAssertEqual(scaleTrigger(0), 0)
        XCTAssertEqual(scaleTrigger(1), 255)
    }

    func testScaleTriggerRoundsHalfValue() {
        // 0.5 * 255 = 127.5 -> rounded to 128
        XCTAssertEqual(scaleTrigger(0.5), 128)
    }

    func testScaleTriggerClampsOverflow() {
        XCTAssertEqual(scaleTrigger(-1), 0)
        XCTAssertEqual(scaleTrigger(2), 255)
    }

    // MARK: - Button bitfield (wire contract parity with Android)

    func testButtonBitsMatchXusb() {
        typealias B = GamepadInputProcessor.Buttons
        XCTAssertEqual(B.dpadUp,        0x0001)
        XCTAssertEqual(B.dpadDown,      0x0002)
        XCTAssertEqual(B.dpadLeft,      0x0004)
        XCTAssertEqual(B.dpadRight,     0x0008)
        XCTAssertEqual(B.start,         0x0010)
        XCTAssertEqual(B.back,          0x0020)
        XCTAssertEqual(B.leftThumb,     0x0040)
        XCTAssertEqual(B.rightThumb,    0x0080)
        XCTAssertEqual(B.leftShoulder,  0x0100)
        XCTAssertEqual(B.rightShoulder, 0x0200)
        XCTAssertEqual(B.a,             0x1000)
        XCTAssertEqual(B.b,             0x2000)
        XCTAssertEqual(B.x,             0x4000)
        XCTAssertEqual(B.y,             0x8000)
    }

    // MARK: - Publish routes to ReportSender

    func testPublishForwardsStateToReportSender() {
        let proc = GamepadInputProcessor()
        var captured: (id: String, w: UInt16, lt: UInt8, rt: UInt8,
                       lx: Int16, ly: Int16, rx: Int16, ry: Int16)?
        proc.reportSender = { id, w, lt, rt, lx, ly, rx, ry in
            captured = (id, w, lt, rt, lx, ly, rx, ry)
        }
        let state = GamepadInputProcessor.DeviceState(
            wButtons: 0x1234, lt: 10, rt: 20,
            lx: 100, ly: -200, rx: 300, ry: -400
        )
        proc.publish(deviceId: "pad-1", state: state)

        XCTAssertEqual(captured?.id, "pad-1")
        XCTAssertEqual(captured?.w,  0x1234)
        XCTAssertEqual(captured?.lt, 10)
        XCTAssertEqual(captured?.rt, 20)
        XCTAssertEqual(captured?.lx, 100)
        XCTAssertEqual(captured?.ly, -200)
        XCTAssertEqual(captured?.rx, 300)
        XCTAssertEqual(captured?.ry, -400)
    }

    func testPublishIncrementsTelemetry() {
        let proc = GamepadInputProcessor()
        proc.reportSender = { _, _, _, _, _, _, _, _ in }
        proc.publish(deviceId: "pad-1", state: .init())
        proc.publish(deviceId: "pad-1", state: .init())
        proc.publish(deviceId: "pad-1", state: .init())

        let snap = proc.drainTelemetry()
        XCTAssertEqual(snap.events, 3)
        XCTAssertEqual(snap.sends,  3)
        XCTAssertEqual(snap.totalSent, 3)

        // drainTelemetry resets counters but keeps totalSent.
        let next = proc.drainTelemetry()
        XCTAssertEqual(next.events, 0)
        XCTAssertEqual(next.sends, 0)
        XCTAssertEqual(next.totalSent, 3)
    }

    // MARK: - zeroAndSendAll fans a release-all report to every known device

    func testZeroAndSendAllEmitsReleasedReportPerDevice() {
        let proc = GamepadInputProcessor()
        var emitted: [(String, UInt16, UInt8, UInt8, Int16, Int16, Int16, Int16)] = []
        proc.reportSender = { id, w, lt, rt, lx, ly, rx, ry in
            emitted.append((id, w, lt, rt, lx, ly, rx, ry))
        }
        proc.publish(deviceId: "a", state: .init(wButtons: 1, lt: 5, rt: 6,
                                                 lx: 7, ly: 8, rx: 9, ry: 10))
        proc.publish(deviceId: "b", state: .init(wButtons: 2, lt: 11, rt: 12,
                                                 lx: 13, ly: 14, rx: 15, ry: 16))
        emitted.removeAll()

        proc.zeroAndSendAll()
        XCTAssertEqual(emitted.count, 2)
        for e in emitted {
            XCTAssertEqual(e.1, 0)
            XCTAssertEqual(e.2, 0)
            XCTAssertEqual(e.3, 0)
            XCTAssertEqual(e.4, 0)
            XCTAssertEqual(e.5, 0)
            XCTAssertEqual(e.6, 0)
            XCTAssertEqual(e.7, 0)
        }
        XCTAssertEqual(Set(emitted.map(\.0)), ["a", "b"])
    }

    func testRemoveDropsDevice() {
        let proc = GamepadInputProcessor()
        var emitted: [String] = []
        proc.reportSender = { id, _, _, _, _, _, _, _ in emitted.append(id) }
        proc.publish(deviceId: "a", state: .init())
        proc.publish(deviceId: "b", state: .init())
        emitted.removeAll()

        proc.remove(deviceId: "a")
        proc.zeroAndSendAll()
        XCTAssertEqual(emitted, ["b"])
    }
}
