import SwiftUI
import UniformTypeIdentifiers

/// FileDocument that reads a .vibeapp package and builds a ready-to-use Project.
/// No library interaction — each document window is fully self-contained.
struct VibeAppDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vibeApp] }
    static var writableContentTypes: [UTType] { [.vibeApp] }

    let project: Project
    /// Current in-memory archive bytes (always plain/unencrypted ZIP).
    /// Updated by the save flow when state is snapshotted.
    var rawPackageData: Data
    /// Set if the package was encrypted on open. Used to re-encrypt on every save.
    var encryptionContext: EncryptionContext?

    // MARK: - Open existing file

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Detect + decrypt encrypted packages before any extraction
        let innerData: Data
        var ctx: EncryptionContext?

        if PackageDecryption.isEncrypted(data) {
            let packageName = configuration.file.filename ?? "this package"
            guard let password = PackageDecryption.promptPassword(forPackage: packageName) else {
                throw CocoaError(.userCancelled)
            }
            do {
                innerData = try PackageDecryption.decrypt(data, password: password)
                ctx = EncryptionContext(password: password)
            } catch {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
                )
            }
        } else {
            innerData = data
        }

        // Persist any _vibe_state/* entries from the file into the cache before
        // cachePackage strips them. Hash is now derived from _vibe_package_manifest.json
        // so it stays stable even after a save rewrites the ZIP with state entries.
        let stateEntries = PackageExtractor.extractStateEntries(from: innerData)

        let pkg = try PackageExtractor.extract(data: innerData)
        let demoKey = Bundle.main.url(forResource: "vibe-official", withExtension: "pub")
            .flatMap { try? Data(contentsOf: $0) }
        let trustResult = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: demoKey)
        let cacheHash = try StorageManager.cachePackage(data: innerData)

        // Cache the app icon so the library can display it regardless of how the file was opened.
        if let iconPath = pkg.appManifest.icon,
           let iconData = try? PackageExtractor.extractFile(named: iconPath, from: innerData) {
            try? iconData.write(to: StorageManager.iconURL(for: cacheHash))
        }

        // Seed state cache from whatever was in the file (preserves state across re-opens)
        if !stateEntries.isEmpty {
            StorageManager.saveState(stateEntries, for: cacheHash)
        }

        rawPackageData = innerData
        encryptionContext = ctx
        project = Project(
            id: UUID(),
            appId: pkg.packageManifest.appId,
            appName: pkg.appManifest.name ?? pkg.packageManifest.appId,
            appVersion: pkg.packageManifest.appVersion,
            publisher: pkg.appManifest.publisher?.name,
            trustStatus: trustResult.status,
            capabilities: AppCapabilities(from: pkg.appManifest),
            packageHash: cacheHash,
            importedAt: Date(),
            packageCachePath: cacheHash,
            originalPackagePath: nil,
            files: pkg.packageManifest.files,
            formatVersion: pkg.packageManifest.formatVersion,
            createdAt: pkg.packageManifest.createdAt,
            isEncrypted: ctx != nil,
            publisherKeyFingerprint: trustResult.keyFingerprint
        )
    }

    // MARK: - New document (required by DocumentGroup(newDocument:editor:))

    /// Placeholder used only when DocumentGroup creates a new document via File > New.
    /// In practice users always open existing .vibeapp files; this state is never persisted.
    init() {
        rawPackageData = Data()
        encryptionContext = nil
        project = Project(
            id: UUID(),
            appId: "",
            appName: "Untitled",
            appVersion: "0",
            publisher: nil,
            trustStatus: .unsigned,
            capabilities: AppCapabilities(),
            packageHash: "",
            importedAt: Date(),
            packageCachePath: "",
            originalPackagePath: nil,
            files: [:],
            formatVersion: "1",
            createdAt: ""
        )
    }

    // MARK: - Write

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Re-encrypt before writing if the package was originally encrypted
        if let ctx = encryptionContext {
            let encrypted = try PackageDecryption.encrypt(rawPackageData, password: ctx.password)
            return FileWrapper(regularFileWithContents: encrypted)
        }
        return FileWrapper(regularFileWithContents: rawPackageData)
    }
}
