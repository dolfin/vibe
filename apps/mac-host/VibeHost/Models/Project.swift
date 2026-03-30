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
    var originalPackagePath: String?

    /// True when this project is pinned to the Favorites section of the library.
    var isFavorite: Bool

    /// The last time this project was opened in a document window.
    var lastOpenedAt: Date?

    /// Files from the package manifest (relative path → SHA-256 hex).
    let files: [String: String]
    let formatVersion: String
    let createdAt: String

    /// True when the package was encrypted with a password at open time.
    let isEncrypted: Bool

    /// Full SHA-256 hex fingerprint of the publisher's Ed25519 public key.
    /// Present when the package carries a signature (verified, trusted, or new publisher).
    /// Used by the TOFU trust prompt to identify and persist publisher trust decisions.
    var publisherKeyFingerprint: String?

    // MARK: - Codable (custom init for backwards-compat; new fields default to nil/false)

    enum CodingKeys: String, CodingKey {
        case id, appId, appName, appVersion, publisher, trustStatus
        case capabilities, packageHash, importedAt, packageCachePath
        case originalPackagePath, files, formatVersion, createdAt, isEncrypted
        case isFavorite, lastOpenedAt, publisherKeyFingerprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appId = try c.decode(String.self, forKey: .appId)
        appName = try c.decode(String.self, forKey: .appName)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        trustStatus = try c.decode(TrustStatus.self, forKey: .trustStatus)
        capabilities = try c.decode(AppCapabilities.self, forKey: .capabilities)
        packageHash = try c.decode(String.self, forKey: .packageHash)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        packageCachePath = try c.decode(String.self, forKey: .packageCachePath)
        originalPackagePath = try c.decodeIfPresent(String.self, forKey: .originalPackagePath)
        files = try c.decode([String: String].self, forKey: .files)
        formatVersion = try c.decode(String.self, forKey: .formatVersion)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        isEncrypted = try c.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        publisherKeyFingerprint = try c.decodeIfPresent(String.self, forKey: .publisherKeyFingerprint)
    }

    // Memberwise initialiser (compiler won't synthesise one once init(from:) is defined).
    init(
        id: UUID,
        appId: String,
        appName: String,
        appVersion: String,
        publisher: String?,
        trustStatus: TrustStatus,
        capabilities: AppCapabilities,
        packageHash: String,
        importedAt: Date,
        packageCachePath: String,
        originalPackagePath: String?,
        files: [String: String],
        formatVersion: String,
        createdAt: String,
        isEncrypted: Bool = false,
        isFavorite: Bool = false,
        lastOpenedAt: Date? = nil,
        publisherKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.appId = appId
        self.appName = appName
        self.appVersion = appVersion
        self.publisher = publisher
        self.trustStatus = trustStatus
        self.capabilities = capabilities
        self.packageHash = packageHash
        self.importedAt = importedAt
        self.packageCachePath = packageCachePath
        self.originalPackagePath = originalPackagePath
        self.files = files
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.isEncrypted = isEncrypted
        self.isFavorite = isFavorite
        self.lastOpenedAt = lastOpenedAt
        self.publisherKeyFingerprint = publisherKeyFingerprint
    }
}
