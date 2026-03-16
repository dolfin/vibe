import Foundation
import CryptoKit
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

    /// Cache a package's archive data under its SHA-256 hash.
    /// Returns the cache key (hash hex) used to look up the package later.
    static func cachePackage(data: Data) throws -> String {
        ensureDirectories()
        let hash = SHA256.hash(data: data)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        let cacheDir = packageCacheDir.appendingPathComponent(hashHex, isDirectory: true)
        let archivePath = cacheDir.appendingPathComponent("package.vibeapp")

        let fm = FileManager.default
        // Check the FILE (not just the directory) to avoid leaving an empty dir
        // from a previously interrupted write.
        if !fm.fileExists(atPath: archivePath.path) {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try data.write(to: archivePath)
            logger.info("Cached package: \(archivePath.path)")
        }

        return hashHex
    }

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
