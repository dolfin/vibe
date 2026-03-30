import Foundation
import ZIPFoundation

/// Parsed contents of a .vibeapp package.
struct VibePackage {
    let packageManifest: PackageManifest
    let appManifest: AppManifest
    let signature: Data?
    let archiveData: Data
}

/// Extracts and parses .vibeapp ZIP archives.
enum PackageExtractor {
    enum ExtractionError: LocalizedError {
        case missingPackageManifest
        case missingAppManifest
        case invalidPackageManifest(String)
        case invalidAppManifest(String)
        case tarExtractionFailed(String)
        case rebuildFailed
        case pathTraversal(String)

        var errorDescription: String? {
            switch self {
            case .missingPackageManifest: "Package is missing _vibe_package_manifest.json"
            case .missingAppManifest: "Package is missing _vibe_app_manifest.json"
            case .invalidPackageManifest(let detail): "Failed to parse _vibe_package_manifest.json: \(detail)"
            case .invalidAppManifest(let detail): "Failed to parse _vibe_app_manifest.json: \(detail)"
            case .tarExtractionFailed(let vol): "Failed to extract state tarball for volume '\(vol)'"
            case .rebuildFailed: "Failed to rebuild package archive"
            case .pathTraversal(let path): "Package contains a path traversal entry: '\(path)'"
            }
        }
    }

    /// Extract a .vibeapp from a file URL.
    static func extract(from url: URL) throws -> VibePackage {
        let data = try Data(contentsOf: url)
        return try extract(data: data)
    }

    /// Extract a .vibeapp from raw data.
    static func extract(data: Data) throws -> VibePackage {
        let archive = try Archive(data: data, accessMode: .read, pathEncoding: nil)

        // Extract _vibe_package_manifest.json
        guard let pkgManifestEntry = archive["_vibe_package_manifest.json"] else {
            throw ExtractionError.missingPackageManifest
        }
        var pkgManifestData = Data()
        _ = try archive.extract(pkgManifestEntry) { chunk in
            pkgManifestData.append(chunk)
        }
        let packageManifest: PackageManifest
        do {
            packageManifest = try JSONDecoder().decode(PackageManifest.self, from: pkgManifestData)
        } catch {
            throw ExtractionError.invalidPackageManifest(error.localizedDescription)
        }

        // Extract _vibe_app_manifest.json
        guard let appManifestEntry = archive["_vibe_app_manifest.json"] else {
            throw ExtractionError.missingAppManifest
        }
        var appManifestData = Data()
        _ = try archive.extract(appManifestEntry) { chunk in
            appManifestData.append(chunk)
        }
        let appManifest: AppManifest
        do {
            appManifest = try AppManifest.fromJSON(appManifestData)
        } catch {
            throw ExtractionError.invalidAppManifest(error.localizedDescription)
        }

        // Extract signature if present
        var signature: Data?
        if let sigEntry = archive["_vibe_signature.sig"] {
            var sigData = Data()
            _ = try archive.extract(sigEntry) { chunk in
                sigData.append(chunk)
            }
            signature = sigData
        }

        return VibePackage(
            packageManifest: packageManifest,
            appManifest: appManifest,
            signature: signature,
            archiveData: data
        )
    }

    /// Extract all app files from a .vibeapp to a directory (skips _vibe_ metadata).
    static func extractAppFiles(from data: Data, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive = try Archive(data: data, accessMode: .read, pathEncoding: nil)

        // Resolve symlinks on the base directory so our prefix check uses the real path.
        let canonicalDir = directory.resolvingSymlinksInPath()

        for entry in archive {
            let name = entry.path
            // Skip metadata files
            if name.hasPrefix("_vibe_") { continue }

            // Reject symlink entries — a symlink pointing outside the sandbox could let
            // a subsequent archive entry escape the extraction directory (ZIP slip via symlink).
            if entry.type == .symlink {
                throw ExtractionError.pathTraversal(name)
            }

            // Build destination from the resolved canonical base so that any symlinks
            // created during a previous iteration are not followed.
            let destURL = canonicalDir.appendingPathComponent(name).standardized

            // Prevent ZIP slip: reject any path that escapes the extraction directory.
            // Use lowercased() comparison because macOS APFS is case-insensitive by default.
            let destLower = destURL.path.lowercased()
            let baseLower = canonicalDir.path.lowercased()
            guard destLower.hasPrefix(baseLower + "/") || destLower == baseLower else {
                throw ExtractionError.pathTraversal(name)
            }

            if entry.type == .directory {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else {
                // Ensure parent directory exists
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                var fileData = Data()
                _ = try archive.extract(entry) { chunk in
                    fileData.append(chunk)
                }
                try fileData.write(to: destURL)
            }
        }
    }

    /// Extract a specific file's data from a .vibeapp archive.
    static func extractFile(named name: String, from data: Data) throws -> Data? {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            return nil
        }
        guard let entry = archive[name] else {
            return nil
        }
        var fileData = Data()
        _ = try archive.extract(entry) { chunk in
            fileData.append(chunk)
        }
        return fileData
    }

    // MARK: - State extraction

    /// Pull out `_vibe_state/<vol>.tar.gz` entries; returns `volName → tarData`.
    static func extractStateEntries(from data: Data) -> [String: Data] {
        extractPrefixedEntries(from: data, prefix: "_vibe_state/")
    }

    /// Pull out `_vibe_initial_state/<vol>.tar.gz` entries; returns `volName → tarData`.
    static func extractInitialStateEntries(from data: Data) -> [String: Data] {
        extractPrefixedEntries(from: data, prefix: "_vibe_initial_state/")
    }

    /// Untar each state entry into `extractDir/<volName>/`.
    static func extractStateTarballs(_ entries: [String: Data], to extractDir: URL) throws {
        let fm = FileManager.default
        for (volName, tarData) in entries {
            let volDir = extractDir.appendingPathComponent(volName, isDirectory: true)
            try fm.createDirectory(at: volDir, withIntermediateDirectories: true)

            // Write tar.gz to a temp file, then extract via system tar
            let tmpURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
            defer { try? fm.removeItem(at: tmpURL) }
            try tarData.write(to: tmpURL)

            // Pre-scan in two passes to avoid ambiguity from spaces in paths:
            //
            // Pass 1 — -tzf (plain list): one path per line, no extra metadata.
            //   Used for path traversal and absolute-path checks.
            //   This format handles paths with spaces correctly.
            //
            // Pass 2 — -tvzf (verbose): permission flags prepended to each line.
            //   Used only for symlink detection: BSD tar prefixes symlink entries
            //   with 'l' and appends " -> <target>".  Either indicator alone is
            //   sufficient to reject the entry; we check both for defence-in-depth.
            let runTar: ([String]) throws -> String = { args in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            }

            // Pass 1: path traversal / absolute-path check
            let plainListing = try runTar(["-tzf", tmpURL.path])
            for entryPath in plainListing.split(separator: "\n").map(String.init) {
                if entryPath.hasPrefix("/") || entryPath.contains("../") || entryPath == ".." {
                    throw ExtractionError.pathTraversal(entryPath)
                }
            }

            // Pass 2: symlink detection
            let verboseListing = try runTar(["-tvzf", tmpURL.path])
            for line in verboseListing.split(separator: "\n").map(String.init) {
                // Symlink entries: permission string starts with 'l' (e.g. "lrwxrwxrwx …")
                // and the path is shown as "name -> target".
                if line.first == "l" || line.contains(" -> ") {
                    throw ExtractionError.pathTraversal("<symlink entry>")
                }
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            // Note: --no-absolute-names is GNU tar only; BSD tar (macOS) does not support it.
            // Absolute path safety is enforced by the pre-scan above.
            proc.arguments = ["-xzf", tmpURL.path, "-C", volDir.path, "--no-same-owner"]
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            try proc.run()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let msg = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw ExtractionError.tarExtractionFailed("\(volName): \(msg)")
            }
        }
    }

    // MARK: - ZIP rebuild

    /// Rebuild the ZIP: copy all base entries (skipping old `_vibe_state/*`), then
    /// append new `_vibe_state/<vol>.tar.gz` entries. Returns new archive bytes.
    static func rebuildWithState(baseData: Data, stateEntries: [String: Data]) throws -> Data {
        let source = try Archive(data: baseData, accessMode: .read, pathEncoding: nil)
        let dest = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)

        for entry in source {
            if entry.path.hasPrefix("_vibe_state/") { continue }
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

        for (volName, tarData) in stateEntries.sorted(by: { $0.key < $1.key }) {
            let size = Int64(tarData.count)
            let captured = tarData
            try dest.addEntry(with: "_vibe_state/\(volName).tar.gz", type: .file,
                              uncompressedSize: size, compressionMethod: .deflate,
                              provider: { pos, chunkSize in
                let start = Int(pos)
                guard start < captured.count else { return Data() }
                return Data(captured[start..<min(start + chunkSize, captured.count)])
            })
        }

        guard let resultData = dest.data else {
            throw ExtractionError.rebuildFailed
        }
        return resultData
    }

    // MARK: - Private helpers

    private static func extractPrefixedEntries(from data: Data, prefix: String) -> [String: Data] {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for entry in archive where entry.path.hasPrefix(prefix) && entry.type == .file {
            let filename = String(entry.path.dropFirst(prefix.count))
            // Strip both extensions from "mydb.tar.gz" → "mydb"
            let volName = URL(fileURLWithPath: filename)
                .deletingPathExtension()
                .deletingPathExtension()
                .lastPathComponent
            guard !volName.isEmpty else { continue }
            var entryData = Data()
            _ = try? archive.extract(entry) { chunk in entryData.append(chunk) }
            result[volName] = entryData
        }
        return result
    }
}
