import Foundation
import CryptoKit
import Observation

/// Observable store managing the project library.
@Observable
final class ProjectStore {
    var projects: [Project] = []

    /// The official Vibe signing public key, bundled in the app.
    /// Packages signed with the corresponding private key (stored as the VIBE_SIGNING_KEY
    /// repo secret) are classified as `.verified` without any user prompt.
    var vibeOfficialPublicKey: Data? {
        guard let url = Bundle.main.url(forResource: "vibe-official", withExtension: "pub") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    init() {
        load()
        importDemoAppsIfNeeded()
    }

    func load() {
        projects = StorageManager.loadProjects()
        // Migrate existing demo apps: ensure they are marked as favorites.
        let demoIds: Set<String> = ["com.example.nodejs-todo", "com.example.sqlite-notes", "com.example.ws-chat"]
        var didMigrate = false
        for idx in projects.indices where demoIds.contains(projects[idx].appId) && !projects[idx].isFavorite {
            projects[idx].isFavorite = true
            didMigrate = true
        }
        if didMigrate { save() }
    }

    func save() {
        StorageManager.saveProjects(projects)
    }

    /// Import a .vibeapp package from a file URL.
    @discardableResult
    func importPackage(from url: URL) throws -> Project {
        let pkg = try PackageExtractor.extract(from: url)

        // Verify trust using the embedded key (TOFU) or the bundled Vibe root key as fallback.
        let trustResult = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: vibeOfficialPublicKey)

        // Cache the package
        let cacheHash = try StorageManager.cachePackage(data: pkg.archiveData)

        // Extract and cache the app icon, if the manifest specifies one
        if let iconPath = pkg.appManifest.icon,
           let iconData = try? PackageExtractor.extractFile(named: iconPath, from: pkg.archiveData) {
            try? iconData.write(to: StorageManager.iconURL(for: cacheHash))
        }

        // Compute package hash hex for display
        let archiveHash = SHA256.hash(data: pkg.archiveData)
        let packageHashHex = archiveHash.map { String(format: "%02x", $0) }.joined()

        // Build capabilities
        let capabilities = AppCapabilities(from: pkg.appManifest)

        let project = Project(
            id: UUID(),
            appId: pkg.packageManifest.appId,
            appName: pkg.appManifest.name ?? pkg.packageManifest.appId,
            appVersion: pkg.packageManifest.appVersion,
            publisher: trustResult.publisherName,
            trustStatus: trustResult.status,
            capabilities: capabilities,
            packageHash: packageHashHex,
            importedAt: Date(),
            packageCachePath: cacheHash,
            originalPackagePath: url.path,
            files: pkg.packageManifest.files,
            formatVersion: pkg.packageManifest.formatVersion,
            createdAt: pkg.packageManifest.createdAt,
            publisherKeyFingerprint: trustResult.keyFingerprint
        )

        projects.append(project)
        save()
        return project
    }

    /// Ensure bundled demo apps are in the library with an up-to-date trust status.
    ///
    /// Called on every launch. Always re-imports each demo via importPackage so that
    /// the library's packageCachePath always matches what the document will compute —
    /// avoiding duplicate entries when the manifest changes (e.g. after key rotation
    /// with --embed-key). The cached file is then force-overwritten with the current
    /// bundle bytes to handle the case where only the signature changed (same manifest
    /// hash, different _vibe_signature.sig). Finally the file is locked (isUserImmutable)
    /// so macOS shows a native padlock in the document title bar.
    private func importDemoAppsIfNeeded() {
        let demoSpecs: [(resource: String, appId: String)] = [
            ("nodejs-todo",    "com.example.nodejs-todo"),
            ("sqlite-notes",   "com.example.sqlite-notes"),
            ("ws-chat",        "com.example.ws-chat"),
        ]

        var needsSave = false

        for spec in demoSpecs {
            guard let url = Bundle.main.url(forResource: spec.resource, withExtension: "vibeapp"),
                  let data = try? Data(contentsOf: url) else { continue }

            // Preserve user-facing state from any existing library entry.
            let existing = projects.first(where: { $0.appId == spec.appId })
            let savedFavorite   = existing?.isFavorite   ?? true   // default true for new demos
            let savedLastOpened = existing?.lastOpenedAt

            // Remove the stale entry and re-import — this ensures packageCachePath always
            // reflects the current bundle manifest, preventing duplicate library entries
            // when the manifest changes between builds.
            projects.removeAll { $0.appId == spec.appId }
            guard (try? importPackage(from: url)) != nil,
                  let idx = projects.firstIndex(where: { $0.appId == spec.appId }) else { continue }

            projects[idx].isFavorite   = savedFavorite
            projects[idx].lastOpenedAt = savedLastOpened
            needsSave = true

            // Force-overwrite the cached file with the current bundle bytes. importPackage
            // calls cachePackage which skips writing if the file already exists — but the
            // existing file may carry a stale signature (same manifest hash, new key).
            var archivePath = StorageManager.packageCacheDir
                .appendingPathComponent(projects[idx].packageCachePath, isDirectory: true)
                .appendingPathComponent("package.vibeapp")
            var unlock = URLResourceValues(); unlock.isUserImmutable = false
            try? archivePath.setResourceValues(unlock)
            try? data.write(to: archivePath)

            // Lock the file — macOS shows a native padlock + Duplicate action.
            var lock = URLResourceValues(); lock.isUserImmutable = true
            try? archivePath.setResourceValues(lock)
        }

        if needsSave { save() }
    }

    /// Called when any document window opens — adds the project to the library if missing,
    /// and updates lastOpenedAt. fileURL is the file that was actually opened (may be cache).
    func registerOpened(_ project: Project, fileURL: URL?) {
        guard !project.packageCachePath.isEmpty else { return }
        let isCached = fileURL.map { $0.path.hasPrefix(StorageManager.packageCacheDir.path) } ?? true
        let originalPath: String? = isCached ? nil : fileURL?.path
        if let idx = projects.firstIndex(where: { $0.packageCachePath == project.packageCachePath }) {
            projects[idx].lastOpenedAt = Date()
            if let p = originalPath {
                projects[idx].originalPackagePath = p
            }
        } else {
            var p = project
            p.originalPackagePath = originalPath
            p.isFavorite = false
            p.lastOpenedAt = Date()
            projects.append(p)
        }
        save()
    }

    func setFavorite(_ project: Project, to isFavorite: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].isFavorite = isFavorite
        save()
    }

    /// Remove a project from the library.
    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()

        // Clean up Keychain secrets
        SecretsManager.deleteAll(for: project.packageCachePath, names: project.capabilities.declaredSecrets)

        // Clean up cache if no other project references it
        let cachePath = StorageManager.packageCacheDir.appendingPathComponent(project.packageCachePath)
        try? FileManager.default.removeItem(at: cachePath)
    }
}
