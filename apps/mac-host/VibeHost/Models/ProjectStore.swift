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
    }

    func load() {
        projects = StorageManager.loadProjects()
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

    /// Remove a project from the library.
    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()

        // Clean up cache if no other project references it
        let cachePath = StorageManager.packageCacheDir.appendingPathComponent(project.packageCachePath)
        try? FileManager.default.removeItem(at: cachePath)
    }
}
