import SwiftUI
import UniformTypeIdentifiers

/// FileDocument that reads a .vibeapp package and builds a ready-to-use Project.
/// No library interaction — each document window is fully self-contained.
struct VibeAppDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vibeApp] }

    let project: Project

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pkg = try PackageExtractor.extract(data: data)
        let demoKey = Bundle.main.url(forResource: "demo-signing", withExtension: "pub")
            .flatMap { try? Data(contentsOf: $0) }
        let trust = PackageVerifier.verifyTrust(package: pkg, publicKey: demoKey)
        let cacheHash = try StorageManager.cachePackage(data: data)
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

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
