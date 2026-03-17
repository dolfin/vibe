import Foundation
import CryptoKit
import ZIPFoundation
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "Storage")

/// Manages local storage for Vibe packages and project registry.
enum StorageManager {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Vibe", isDirectory: true)
    }()

    static let packageCacheDir: URL = {
        appSupportDir.appendingPathComponent("package-cache", isDirectory: true)
    }()

    static let projectsFileURL: URL = {
        appSupportDir.appendingPathComponent("projects.json")
    }()

    /// Ensure storage directories exist.
    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: packageCacheDir, withIntermediateDirectories: true)
    }

    /// Cache a package's archive data under a stable key derived from `_vibe_package_manifest.json`.
    ///
    /// The package manifest is in the signed section and never changes, so the cache key is
    /// identical before and after user saves (which only add `_vibe_state/*` entries).
    /// The cached archive is the state-stripped version used as base in `rebuildWithState`.
    ///
    /// Returns the cache key (hash hex) used to look up the package later.
    static func cachePackage(data: Data) throws -> String {
        ensureDirectories()

        // Derive hash from the signed _vibe_package_manifest.json — stable across saves.
        let hashInput = manifestData(from: data) ?? data
        let hash = SHA256.hash(data: hashInput)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        let cacheDir = packageCacheDir.appendingPathComponent(hashHex, isDirectory: true)
        let archivePath = cacheDir.appendingPathComponent("package.vibeapp")

        let fm = FileManager.default
        if !fm.fileExists(atPath: archivePath.path) {
            // Cache the state-stripped bytes so rebuildWithState always starts from a clean base.
            let strippedData = (try? stripStateEntries(from: data)) ?? data
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try strippedData.write(to: archivePath)
            logger.info("Cached package: \(archivePath.path)")
        }

        return hashHex
    }

    /// Returns the directory where per-package user state tarballs are stored.
    /// Path: `package-cache/<hash>/state/`
    static func stateDir(for packageHash: String) -> URL {
        packageCacheDir
            .appendingPathComponent(packageHash, isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    /// Persist state tarballs (`volName → tar.gz bytes`) for a package hash.
    static func saveState(_ entries: [String: Data], for hash: String) {
        let dir = stateDir(for: hash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (vol, tarData) in entries {
            let url = dir.appendingPathComponent("\(vol).tar.gz")
            try? tarData.write(to: url, options: .atomic)
        }
        logger.info("Saved state for \(hash): \(entries.keys.sorted().joined(separator: ", "))")
    }

    /// Load all saved state tarballs for a package hash. Returns empty dict if none.
    static func loadState(for hash: String) -> [String: Data] {
        let dir = stateDir(for: hash)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [:] }
        var result: [String: Data] = [:]
        for url in items where url.pathExtension == "gz" {
            // file is "<vol>.tar.gz"; strip both extensions to get volume name
            let volName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard !volName.isEmpty else { continue }
            if let data = try? Data(contentsOf: url) {
                result[volName] = data
            }
        }
        return result
    }

    // MARK: - Private helpers

    /// Read `_vibe_package_manifest.json` bytes from the archive — used as stable hash input.
    private static func manifestData(from data: Data) -> Data? {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil),
              let entry = archive["_vibe_package_manifest.json"] else { return nil }
        var result = Data()
        _ = try? archive.extract(entry) { chunk in result.append(chunk) }
        return result.isEmpty ? nil : result
    }

    /// Rebuild the ZIP in-memory with all `_vibe_state/*` entries removed.
    private static func stripStateEntries(from data: Data) throws -> Data {
        let source = try Archive(data: data, accessMode: .read, pathEncoding: nil)
        let dest = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        for entry in source {
            guard !entry.path.hasPrefix("_vibe_state/") else { continue }
            var entryData = Data()
            _ = try source.extract(entry) { chunk in entryData.append(chunk) }
            if entry.type == .directory {
                try dest.addEntry(with: entry.path, type: .directory, uncompressedSize: 0 as Int64,
                                  compressionMethod: .none, provider: { _, _ in Data() })
            } else {
                let size = Int64(entryData.count)
                let captured = entryData
                try dest.addEntry(with: entry.path, type: .file, uncompressedSize: size,
                                  compressionMethod: .deflate,
                                  provider: { pos, chunkSize in
                    let start = Int(pos)
                    guard start < captured.count else { return Data() }
                    return Data(captured[start..<min(start + chunkSize, captured.count)])
                })
            }
        }
        return dest.data ?? data
    }

    /// Returns the total size and last modification date of saved state for a package hash.
    static func stateInfo(for packageHash: String) -> (totalBytes: Int, lastSaved: Date?) {
        let dir = stateDir(for: packageHash)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return (0, nil) }
        var total = 0
        var latest: Date?
        for url in items where url.pathExtension == "gz" {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                total += values.fileSize ?? 0
                if let date = values.contentModificationDate {
                    if latest == nil || date > latest! { latest = date }
                }
            }
        }
        return (total, latest)
    }

    // MARK: - Project persistence

    /// Load projects from disk.
    static func loadProjects() -> [Project] {
        ensureDirectories()
        logger.info("Loading projects from: \(projectsFileURL.path)")
        guard let data = try? Data(contentsOf: projectsFileURL) else {
            logger.info("No projects.json found, starting fresh")
            return []
        }
        logger.info("Read \(data.count) bytes from projects.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let projects = try decoder.decode([Project].self, from: data)
            logger.info("Loaded \(projects.count) projects")
            return projects
        } catch {
            logger.error("Failed to decode projects.json: \(String(describing: error))")
            return []
        }
    }

    /// Save projects to disk.
    static func saveProjects(_ projects: [Project]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: projectsFileURL, options: .atomic)
    }
}
