import Foundation
import CryptoKit
import Observation

/// Observable store managing the project library.
@Observable
final class ProjectStore {
    var projects: [Project] = []

    /// Bundled demo public key for verifying example packages.
    var demoPublicKey: Data? {
        guard let url = Bundle.main.url(forResource: "demo-signing", withExtension: "pub") else {
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
    func importPackage(from url: URL, publicKey: Data? = nil) throws -> Project {
        let pkg = try PackageExtractor.extract(from: url)

        // Determine the public key to use
        let keyToUse = publicKey ?? demoPublicKey

        // Verify trust
        let trustStatus = PackageVerifier.verifyTrust(package: pkg, publicKey: keyToUse)

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
            publisher: pkg.appManifest.publisher?.name,
            trustStatus: trustStatus,
            capabilities: capabilities,
            packageHash: packageHashHex,
            importedAt: Date(),
            packageCachePath: cacheHash,
            originalPackagePath: url.path,
            files: pkg.packageManifest.files,
            formatVersion: pkg.packageManifest.formatVersion,
            createdAt: pkg.packageManifest.createdAt
        )

        projects.append(project)
        save()
        return project
    }

    /// Auto-import bundled demo apps, replacing any existing entries with the same appId.
    private func importDemoAppsIfNeeded() {
        let key = "vibe.demosImported.v3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Remove any existing demo entries so fresh imports take precedence in favorites.
        let demoIds: Set<String> = ["com.example.nodejs-todo", "com.example.sqlite-notes", "com.example.ws-chat"]
        projects.removeAll { demoIds.contains($0.appId) }
        let demos = ["nodejs-todo", "sqlite-notes", "ws-chat"]
        for name in demos {
            guard let url = Bundle.main.url(forResource: name, withExtension: "vibeapp") else { continue }
            try? importPackage(from: url)
            // Mark the just-added demo project as a favorite.
            if let idx = projects.firstIndex(where: { $0.originalPackagePath == url.path }) {
                projects[idx].isFavorite = true
            }
        }
        save()
        UserDefaults.standard.set(true, forKey: key)
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
