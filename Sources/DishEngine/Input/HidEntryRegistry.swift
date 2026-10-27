// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

/// The Direct reader's devices, one record per IORegistry entry.
///
/// IOHIDManager hands back a separate device reference for every matching
/// rule a device satisfies: a Nintendo pad matches its model rule and the
/// gamepad rule, so it arrives twice and leaves twice. The registry entry ID
/// is the one identity both references share, so a device is read once and
/// ended once, whichever reference reports it.
struct HidEntryRegistry<Entry> {
    /// What the reader is doing with one device.
    private enum Record {
        /// Read through this entry's lane.
        case reading(Entry)
        /// Handed back to GameController: a late second reference is not read.
        case released
    }

    private var records: [UInt64: Record] = [:]

    /// Whether the device is already known, read or released.
    func knows(_ registryId: UInt64) -> Bool {
        records[registryId] != nil
    }

    /// The entries being read, in registry order.
    var reading: [Entry] {
        let ordered = records.sorted { $0.key < $1.key }
        return ordered.compactMap { Self.readingEntry($0.value) }
    }

    /// Files a device's entry; a device already known keeps its record.
    mutating func file(_ registryId: UInt64, _ entry: Entry) {
        guard records[registryId] == nil else { return }
        records[registryId] = .reading(entry)
    }

    /// The device left: its entry when it was being read.
    mutating func remove(_ registryId: UInt64) -> Entry? {
        let record = records.removeValue(forKey: registryId)
        return record.flatMap(Self.readingEntry)
    }

    /// Stops reading the first entry that matches; the device stays known,
    /// as released, until it leaves.
    mutating func release(where matches: (Entry) -> Bool) -> Entry? {
        guard let found = firstReading(where: matches) else { return nil }
        records[found.registryId] = .released
        return found.entry
    }

    /// Forgets every device macOS no longer lists and returns the entries
    /// among them that were being read, so their lanes close: a removal the
    /// manager never reported cannot leave a ghost pad.
    mutating func reconcile(present: Set<UInt64>) -> [Entry] {
        let gone = records.keys.filter { !present.contains($0) }.sorted()
        return gone.compactMap { remove($0) }
    }

    private func firstReading(where matches: (Entry) -> Bool) -> (registryId: UInt64, entry: Entry)? {
        let ordered = records.sorted { $0.key < $1.key }
        for (registryId, record) in ordered {
            guard let entry = Self.readingEntry(record), matches(entry) else { continue }
            return (registryId, entry)
        }
        return nil
    }

    private static func readingEntry(_ record: Record) -> Entry? {
        switch record {
        case let .reading(entry): entry
        case .released: nil
        }
    }
}
