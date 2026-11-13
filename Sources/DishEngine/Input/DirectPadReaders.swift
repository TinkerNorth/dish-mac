// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The paths' one reader over several, the HID reader and the XUSB reader
/// in the app: each hears every call and acts only on the slots it opened.
final class DirectPadReaders: HidPadReading {
    private let readers: [any HidPadReading]

    init(_ readers: [any HidPadReading]) {
        self.readers = readers
    }

    func start(wiring: HidPadWiring, events: HidPadEvents) {
        for reader in readers {
            reader.start(wiring: wiring, events: events)
        }
    }

    func release(slotId: String) {
        for reader in readers {
            reader.release(slotId: slotId)
        }
    }

    func claim(slotId: String) {
        for reader in readers {
            reader.claim(slotId: slotId)
        }
    }

    func unclaim(slotId: String) {
        for reader in readers {
            reader.unclaim(slotId: slotId)
        }
    }
}
