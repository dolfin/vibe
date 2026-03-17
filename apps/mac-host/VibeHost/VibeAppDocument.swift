import SwiftUI
import UniformTypeIdentifiers

/// FileDocument that reads a .vibeapp package and builds a ready-to-use Project.
/// No library interaction — each document window is fully self-contained.
struct VibeAppDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vibeApp] }
    static var writableContentTypes: [UTType] { [.vibeApp] }

    let project: Project
    /// Current in-memory archive bytes. Updated by the save flow when state is snapshotted.
    var rawPackageData: Data

    // MARK: - Open existing file

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Persist any _vibe_state/* entries from the file into the cache before
        // cachePackage strips them. Hash is now derived from _vibe_package_manifest.json
        // so it stays stable even after a save rewrites the ZIP with state entries.
        let stateEntries = PackageExtractor.extractStateEntries(from: data)

        let pkg = try PackageExtractor.extract(data: data)
        let demoKey = Bundle.main.url(forResource: "demo-signing", withExtension: "pub")
            .flatMap { try? Data(contentsOf: $0) }
        let trust = PackageVerifier.verifyTrust(package: pkg, publicKey: demoKey)
        let cacheHash = try StorageManager.cachePackage(data: data)

        // Seed state cache from whatever was in the file (preserves state across re-opens)
        if !stateEntries.isEmpty {
            StorageManager.saveState(stateEntries, for: cacheHash)
        }

        rawPackageData = data
        project = Project(
            id: UUID(),
            appId: pkg.packageManifest.appId,
            appName: pkg.appManifest.name ?? pkg.packageManifest.appId,
            appVersion: pkg.packageManifest.appVersion,
            publisher: pkg.appManifest.publisher?.name,
            trustStatus: trust,
            capabilities: AppCapabilities(from: pkg.appManifest),
            packageHash: cacheHash,
            importedAt: Date(),
            packageCachePath: cacheHash,
            originalPackagePath: nil,
            files: pkg.packageManifest.files,
            formatVersion: pkg.packageManifest.formatVersion,
            createdAt: pkg.packageManifest.createdAt
        )
    }

    // MARK: - New document (required by DocumentGroup(newDocument:editor:))

    /// Placeholder used only when DocumentGroup creates a new document via File > New.
    /// In practice users always open existing .vibeapp files; this state is never persisted.
    init() {
        rawPackageData = Data()
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
        FileWrapper(regularFileWithContents: rawPackageData)
    }
}
