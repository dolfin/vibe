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

        var errorDescription: String? {
            switch self {
            case .missingPackageManifest: "Package is missing _vibe_package_manifest.json"
            case .missingAppManifest: "Package is missing _vibe_app_manifest.json"
            case .invalidPackageManifest(let detail): "Failed to parse _vibe_package_manifest.json: \(detail)"
            case .invalidAppManifest(let detail): "Failed to parse _vibe_app_manifest.json: \(detail)"
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
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw ExtractionError.missingPackageManifest
        }

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

    /// Extract a specific file's data from a .vibeapp archive.
    static func extractFile(named name: String, from data: Data) throws -> Data? {
        guard let archive = Archive(data: data, accessMode: .read) else {
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
}
