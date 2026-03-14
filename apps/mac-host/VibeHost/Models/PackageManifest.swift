import Foundation

/// Maps to `_vibe_package_manifest.json` inside a .vibeapp archive.
struct PackageManifest: Codable {
    let formatVersion: String
    let appId: String
    let appVersion: String
    let createdAt: String
    let files: [String: String]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case appId = "app_id"
        case appVersion = "app_version"
        case createdAt = "created_at"
        case files
    }
}
