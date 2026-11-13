// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The paths' one reader over the HID and the XUSB readers.
final class DirectPadReadersTests: XCTestCase {

    func testEveryReaderHearsEveryCall() {
        let hid = FakeHidPadReader()
        let xusb = FakeHidPadReader()
        let readers = DirectPadReaders([hid, xusb])
        let wiring = HidPadWiring(processor: GamepadInputProcessor(), notify: ignoreGateEvent, battery: { _, _ in })
        readers.start(wiring: wiring, events: HidPadEvents(arrived: { _ in }, removed: { _ in }))
        readers.claim(slotId: "hid:28de:1102")
        readers.unclaim(slotId: "hid:28de:1102")
        readers.release(slotId: "hid:057e:2009")
        for reader in [hid, xusb] {
            XCTAssertNotNil(reader.wiring)
            XCTAssertEqual(reader.claims, [.claim("hid:28de:1102"), .unclaim("hid:28de:1102")])
            XCTAssertEqual(reader.released, ["hid:057e:2009"])
        }
    }
}
