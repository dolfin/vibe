import Foundation

/// A Vibe project imported into the host app library.
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    let appId: String
    let appName: String
    let appVersion: String
    let publisher: String?
    var trustStatus: TrustStatus
    let capabilities: AppCapabilities
    let packageHash: String
    let importedAt: Date
    let packageCachePath: String

    /// Original file path of the .vibeapp (outside sandbox, for supervisor).
    let originalPackagePath: String?

    /// Files from the package manifest (relative path → SHA-256 hex).
    let files: [String: String]
    let formatVersion: String
    let createdAt: String
}
