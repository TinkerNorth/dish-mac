// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
@testable import DishEngine

/// A website in memory: it answers as scripted and writes down every
/// request, so a test can say none was made.
final class RecordingControllerDbGateway: ControllerDbGateway, @unchecked Sendable {
    enum Request: Equatable {
        case manifest(etag: String?)
        case file(String)
    }

    private let requestsBox = LockedBox<[Request]>([])
    var manifest = ManifestReply.unreachable
    var files: [String: Data] = [:]

    var requests: [Request] {
        requestsBox.get()
    }

    func fetchManifest(etag: String?) async -> ManifestReply {
        requestsBox.mutate { $0.append(.manifest(etag: etag)) }
        return manifest
    }

    func fetchFile(_ path: String) async -> Data? {
        requestsBox.mutate { $0.append(.file(path)) }
        return files[path]
    }
}

/// One published version as the website would serve it.
struct ServedVersion {
    let manifestData: Data
    let files: [String: Data]

    init(dbVersion: Int, recordId: String = "served-pad", usb: String = "1234:5678") throws {
        let record: [String: Any] = [
            "schema": 1, "id": recordId, "requires": ["families": ["hid"], "ops": []],
            "identity": ["usb": [usb], "bluetooth": []],
            "input": ["protocol": ["ref": "hid"], "direct": ["rule": "auto"]],
            "support": ["verification": ["state": "imported"]]
        ]
        let database = try JSONSerialization.data(withJSONObject: ["schema": 1, "dbVersion": dbVersion, "records": [record]])
        let english = try JSONSerialization.data(withJSONObject: ["controller.\(recordId).name": "Served Pad"])
        let files = [ControllerDbFiles.controllers: database, ControllerDbFiles.strings("en"): english]
        let entries = files.mapValues { ["sha256": sha256Hex($0), "bytes": $0.count] as [String: Any] }
        manifestData = try JSONSerialization.data(withJSONObject: ["schema": 1, "dbVersion": dbVersion, "files": entries])
        self.files = files
    }

    var set: ControllerDbSet? {
        guard case let .success(manifest) = decodeControllerDbManifest(manifestData) else { return nil }
        return verifiedControllerDbSet(manifest: manifest, files: files)
    }
}

func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dish-test-\(UUID().uuidString)")
}
