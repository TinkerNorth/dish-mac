// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// A record as the website writes one, to be changed field by field.
struct RecordFixture {
    var json: [String: Any] = [
        "schema": 1,
        "id": "sony-dualsense",
        "requires": ["families": ["dualsense"], "ops": []],
        "identity": ["usb": ["054c:0ce6"], "bluetooth": []],
        "input": [
            "protocol": ["ref": "dualsense", "streamsUnprompted": true],
            "direct": ["rule": "auto"],
            "capabilities": ["motion": true, "touchpad": true, "trackpads": 0, "battery": true, "extendedButtons": false]
        ],
        "output": [
            "route": "interruptOut",
            "init": ["kind": "none"],
            "capabilities": [
                "rumble": true,
                "triggerRumble": false,
                "lightbar": true,
                "playerLeds": true,
                "micLed": true,
                "triggerEffects": true
            ]
        ],
        "expect": ["endpoints": ["in": true, "out": true]],
        "support": [
            "verification": ["state": "verified", "transport": "usb"],
            "issues": [
                [
                    "id": "thor-ds5-rumble-usb",
                    "device": "AYN Thor",
                    "os": ["android": 15],
                    "transport": "usb",
                    "lane": "output.rumble",
                    "status": "open"
                ]
            ]
        ]
    ]

    func with(_ path: [String], _ value: Any?) -> RecordFixture {
        var copy = self
        copy.json = setting(json, path, value)
        return copy
    }
}

private func setting(_ object: [String: Any], _ path: [String], _ value: Any?) -> [String: Any] {
    var copy = object
    guard let head = path.first else { return copy }
    guard path.count > 1 else {
        copy[head] = value
        return copy
    }
    let child = copy[head] as? [String: Any] ?? [:]
    copy[head] = setting(child, Array(path.dropFirst()), value)
    return copy
}

func databaseData(schema: Any? = 1, dbVersion: Int = 1, records: [[String: Any]]) throws -> Data {
    var json: [String: Any] = ["dbVersion": dbVersion, "records": records]
    if let schema { json["schema"] = schema }
    return try JSONSerialization.data(withJSONObject: json)
}

/// A whole published set in memory: the files and the manifest that names them.
struct PublishedSet {
    let files: [String: Data]
    let manifest: ControllerDbManifest
    let manifestData: Data

    init(dbVersion: Int, records: [[String: Any]] = [RecordFixture().json], strings: [String: [String: String]]? = nil) throws {
        let tables = strings ?? ["en": ["controller.sony-dualsense.name": "DualSense Wireless Controller"]]
        var files = try [ControllerDbFiles.controllers: databaseData(dbVersion: dbVersion, records: records)]
        for (locale, table) in tables {
            files[ControllerDbFiles.strings(locale)] = try JSONSerialization.data(withJSONObject: table)
        }
        let entries = files.mapValues { ["sha256": sha256Hex($0), "bytes": $0.count] as [String: Any] }
        let manifestJson: [String: Any] = ["schema": 1, "dbVersion": dbVersion, "publishedAt": "2026-11-19T00:00:00Z", "files": entries]
        manifestData = try JSONSerialization.data(withJSONObject: manifestJson)
        guard case let .success(manifest) = decodeControllerDbManifest(manifestData) else { throw FixtureError.manifest }
        self.files = files
        self.manifest = manifest
    }

    var set: ControllerDbSet? {
        verifiedControllerDbSet(manifest: manifest, files: files)
    }
}

enum FixtureError: Error {
    case manifest
}
