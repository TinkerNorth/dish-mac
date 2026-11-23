// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The downloaded controller data, on disk under Application Support: one
// file per published path. A new version is written beside the old one and
// renamed over it whole, so a crash mid-write leaves the previous version.
// Nothing but the manifest, the database and a locale's strings is written.

import DishCore
import DishKernel
import Foundation

final class ControllerDbCache: Repository, @unchecked Sendable {
    typealias Key = String
    typealias Value = Data

    /// `~/Library/Application Support/Dish/controllers-v1`.
    static func live() -> ControllerDbCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ControllerDbCache(directory: support.appendingPathComponent("Dish").appendingPathComponent(BundledControllerDb.folder))
    }

    let directory: URL
    private let lock = LockedBox<Void>((), name: "controllerDb.cache")

    init(directory: URL) {
        self.directory = directory
    }

    func get(_ key: String) -> Data? {
        guard isCachePath(key) else { return nil }
        return lock.mutate { _ in try? Data(contentsOf: url(key)) }
    }

    func all() -> [Data] {
        lock.mutate { _ in paths().compactMap { try? Data(contentsOf: url($0)) } }
    }

    func put(_ value: Data, for key: String) {
        guard isCachePath(key) else { return }
        lock.mutate { _ in write(value, to: url(key)) }
    }

    func remove(_ key: String) {
        guard isCachePath(key) else { return }
        lock.mutate { _ in removeIfThere(url(key)) }
    }

    func clear() {
        lock.mutate { _ in removeIfThere(directory) }
    }

    /// Every file by its path, the manifest among them.
    func files() -> [String: Data] {
        lock.mutate { _ in
            var files: [String: Data] = [:]
            for path in paths() {
                files[path] = try? Data(contentsOf: url(path))
            }
            return files
        }
    }

    /// The whole set replaced at once: written into a sibling folder, then
    /// renamed over the old one. False leaves the old set as it was; a path
    /// that is not the database's refuses the whole set.
    func replaceAll(_ files: [String: Data]) -> Bool {
        guard files.keys.allSatisfy(isCachePath) else { return false }
        return lock.mutate { _ in swapIn(files) }
    }

    /// The cached set, verified against the manifest it came with; nil for
    /// none, and for a folder someone changed.
    func load() -> ControllerDbSet? {
        let files = files()
        guard let body = files[ControllerDbFiles.manifest],
              case let .success(manifest) = decodeControllerDbManifest(body) else { return nil }
        return verifiedControllerDbSet(manifest: manifest, files: files)
    }

    // MARK: - Under the lock

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(key)
    }

    private func paths() -> [String] {
        let root = directory.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let urls = walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        return urls.map { $0.standardizedFileURL.path.replacingOccurrences(of: root, with: "") }.sorted()
    }

    private func write(_ data: Data, to file: URL) {
        let folder = file.deletingLastPathComponent()
        let made = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        guard made else { return }
        let written = (try? data.write(to: file, options: .atomic)) != nil
        guard written else { return }
    }

    private func removeIfThere(_ item: URL) {
        guard FileManager.default.fileExists(atPath: item.path) else { return }
        let removed = (try? FileManager.default.removeItem(at: item)) != nil
        guard removed else { return }
    }

    private func swapIn(_ files: [String: Data]) -> Bool {
        let staging = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".staging")
        removeIfThere(staging)
        for (path, data) in files {
            write(data, to: staging.appendingPathComponent(path))
        }
        let staged = files.keys.allSatisfy { FileManager.default.fileExists(atPath: staging.appendingPathComponent($0).path) }
        guard staged else { return false }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return (try? FileManager.default.moveItem(at: staging, to: directory)) != nil
        }
        return (try? FileManager.default.replaceItemAt(directory, withItemAt: staging)) != nil
    }
}

/// The manifest, which the cache keeps beside the files, or a database path.
private func isCachePath(_ path: String) -> Bool {
    path == ControllerDbFiles.manifest || isControllerDbPath(path)
}
