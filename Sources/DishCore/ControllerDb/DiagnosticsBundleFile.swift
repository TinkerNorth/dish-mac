// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// `dish-diagnostics.v1` as it is encoded: the contract's keys, a field the
// client does not know written as null where the contract shows one.

import Foundation

// MARK: - The encoded shape

struct BundleFile: Encodable {
    struct App: Encodable {
        let name: String
        let version: String
        let build: String
        let flavor: String
    }

    struct Device: Encodable {
        let model: String
        let os: String
        let arch: String
        let conditions: Conditions?

        private enum CodingKeys: String, CodingKey { case model, os, arch, battery, thermal, powerSave, wifi, usbHost }

        /// The conditions sit beside the model, each null where this Mac does
        /// not have it; none of them when they were not read.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(os, forKey: .os)
            try container.encode(arch, forKey: .arch)
            guard let conditions else { return }
            try container.encode(conditions.battery, forKey: .battery)
            try container.encode(conditions.thermal, forKey: .thermal)
            try container.encode(conditions.powerSave, forKey: .powerSave)
            try container.encode(conditions.wifi, forKey: .wifi)
            try container.encode(conditions.usbHost, forKey: .usbHost)
        }
    }

    struct Conditions {
        let battery: BatteryFile?
        let thermal: String?
        let powerSave: Bool?
        let wifi: WifiFile?
        let usbHost: Bool?
    }

    struct ControllerDb: Encodable {
        let bundledVersion: Int
        let activeVersion: Int
        let source: String
        let lastCheckAt: String?
        let lastCheckResult: String?
    }

    struct Hardware: Encodable {
        let vid: String
        let pid: String
        let bcdDevice: String?
        let product: String?
        let manufacturer: String?
        let interfaces: [Interface]?
        let endpoints: Endpoints?
        let descriptorSha256: String?

        private enum CodingKeys: String, CodingKey {
            case vid, pid, bcdDevice, product, manufacturer, interfaces, endpoints, descriptorSha256, firmware
        }

        /// Every key the contract shows is written, null where IOKit gave
        /// nothing; IOKit names no firmware for a pad, so that one always is.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(vid, forKey: .vid)
            try container.encode(pid, forKey: .pid)
            try container.encode(bcdDevice, forKey: .bcdDevice)
            try container.encode(product, forKey: .product)
            try container.encode(manufacturer, forKey: .manufacturer)
            try container.encode(interfaces, forKey: .interfaces)
            try container.encode(endpoints, forKey: .endpoints)
            try container.encode(descriptorSha256, forKey: .descriptorSha256)
            try container.encodeNil(forKey: .firmware)
        }
    }

    struct Interface: Encodable {
        let number: Int
        let interfaceClass: String
        let subclass: String
        let interfaceProtocol: String

        private enum CodingKeys: String, CodingKey {
            case number, interfaceClass = "class", subclass, interfaceProtocol = "protocol"
        }
    }

    struct Endpoints: Encodable {
        let input: String
        let output: String?

        private enum CodingKeys: String, CodingKey { case input = "in", output = "out" }

        /// An OUT endpoint the interface lacks is null.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(input, forKey: .input)
            try container.encode(output, forKey: .output)
        }
    }

    struct Audio: Encodable {
        let channels: Int
        let refused: Bool
    }

    struct Write: Encodable {
        let route: String
        let reportId: String
        let ok: Bool
        let err: String?
        let atMs: Int64
    }

    struct Outcome: Encodable {
        let test: String
        let result: String
        let atMs: Int64
    }

    /// The contract's capture object; the Mac's format is its Help-support text.
    struct Capture: Encodable {
        static let supportCaptureText = "support-capture-text"

        let format: String
        let text: String
    }

    struct Feedback: Encodable {
        let kind: String
        let atMs: Int64
        let count: Int
    }

    struct Controller: Encodable {
        let record: String?
        let verification: String?
        let transport: String?
        let path: String
        let hardware: Hardware?
        let expectMismatch: [String]
        let rateHz: Int?
        let audio: Audio?
        let lastFeedback: Feedback?
        let lastWrite: Write?
        let outcomes: [Outcome]
        let capture: Capture?
        let input: BundlePadPathsFile.Input?
        let output: BundlePadPathsFile.Output?
        let bluetooth: BundlePadPathsFile.Bluetooth?

        private enum CodingKeys: String, CodingKey {
            case record, verification, transport, path, hardware, expectMismatch, probe, rateHz, audio, lastFeedback, lastWrite
            case outcomes, capture, input, output, bluetooth
        }

        /// `record`, `capture`, `rateHz` and `audio` are written as null when
        /// there is none, as the contract shows them. `probe` is always null:
        /// the Mac's gate is GameController's answer, not a decode probe.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(record, forKey: .record)
            try container.encodeIfPresent(verification, forKey: .verification)
            try container.encodeIfPresent(transport, forKey: .transport)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(hardware, forKey: .hardware)
            try container.encode(expectMismatch, forKey: .expectMismatch)
            try container.encodeNil(forKey: .probe)
            try container.encode(rateHz, forKey: .rateHz)
            try container.encode(audio, forKey: .audio)
            try container.encodeIfPresent(lastFeedback, forKey: .lastFeedback)
            try container.encodeIfPresent(lastWrite, forKey: .lastWrite)
            try container.encode(outcomes, forKey: .outcomes)
            try container.encode(capture, forKey: .capture)
            try container.encodeIfPresent(input, forKey: .input)
            try container.encodeIfPresent(output, forKey: .output)
            try container.encode(bluetooth, forKey: .bluetooth)
        }
    }

    struct Grants: Encodable {
        let mic: Bool
        let speaker: Bool
        let hapticAudio: Bool
    }

    struct Snapshot {
        let document: JSONValue?
        let error: String?
    }

    struct Host: Encodable {
        let alias: String
        let kind: String
        let version: String?
        let protocolVersion: Int?
        let link: String
        let grants: Grants?
        let session: BundleSessionFile?
        let snapshot: Snapshot?

        private enum CodingKeys: String, CodingKey {
            case alias, kind, version, protocolVersion = "protocol", link, grants, session, snapshot, snapshotError
        }

        /// `snapshot` and `snapshotError` are written, null included, once
        /// the host was asked.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(alias, forKey: .alias)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(version, forKey: .version)
            try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
            try container.encode(link, forKey: .link)
            try container.encodeIfPresent(grants, forKey: .grants)
            try container.encodeIfPresent(session, forKey: .session)
            guard let snapshot else { return }
            try container.encode(snapshot.document, forKey: .snapshot)
            try container.encode(snapshot.error, forKey: .snapshotError)
        }
    }

    struct Log: Encodable {
        let atMs: Int64
        let tag: String
        let message: String
    }

    let bundle: Int
    let createdAt: String
    let app: App
    let device: Device
    let controllerDb: ControllerDb
    let controllers: [Controller]
    let hosts: [Host]
    let log: [Log]
    let report: SupportReportFile?
}
