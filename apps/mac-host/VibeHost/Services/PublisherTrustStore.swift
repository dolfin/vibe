import Foundation
import CryptoKit
import Observation

/// A record of a publisher whose signing key this user has explicitly trusted.
struct PublisherEntry: Codable, Identifiable {
    var id: String { fingerprint }
    /// Full SHA-256 hex fingerprint of the raw 32-byte Ed25519 public key.
    let fingerprint: String
    let publisherName: String
    let trustedAt: Date
}

/// Persistent local trust store implementing Trust On First Use (TOFU).
///
/// When a package is signed by an unknown key, the user is prompted once.
/// On approval the key fingerprint is stored here, and all future packages
/// from the same key are automatically trusted without prompting.
///
/// Use `PublisherTrustStore.shared` in production code.
/// In tests, create a fresh `PublisherTrustStore()` — it is in-memory only.
@Observable
final class PublisherTrustStore {
    private(set) var entries: [PublisherEntry] = []
    private let persistent: Bool

    static let shared = PublisherTrustStore(persistent: true)

    /// Creates an in-memory store (no disk reads or writes). Use in tests.
    init() { self.persistent = false }

    private init(persistent: Bool) {
        self.persistent = persistent
        if persistent { load() }
    }

    // MARK: - Queries

    func isTrusted(fingerprint: String) -> Bool {
        entries.contains { $0.fingerprint == fingerprint }
    }

    // MARK: - Mutations

    /// Add a fingerprint to the trust store. No-op if already trusted.
    func trust(fingerprint: String, publisherName: String) {
        guard !isTrusted(fingerprint: fingerprint) else { return }
        entries.append(PublisherEntry(fingerprint: fingerprint, publisherName: publisherName, trustedAt: Date()))
        save()
    }

    /// Convenience: compute fingerprint from raw key bytes, then trust it.
    func trust(keyData: Data, publisherName: String) {
        trust(fingerprint: Self.fingerprint(for: keyData), publisherName: publisherName)
    }

    /// Remove a fingerprint from the trust store.
    func revoke(fingerprint: String) {
        entries.removeAll { $0.fingerprint == fingerprint }
        save()
    }

    // MARK: - Fingerprint helpers

    /// Full SHA-256 hex fingerprint of a raw 32-byte Ed25519 public key.
    static func fingerprint(for keyData: Data) -> String {
        SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
    }

    /// Short fingerprint for display: first 16 hex chars in groups of 4.
    /// Example: "a1b2 c3d4 e5f6 7890"
    static func shortFingerprint(for keyData: Data) -> String {
        let full = fingerprint(for: keyData)
        let prefix = String(full.prefix(16))
        return stride(from: 0, to: prefix.count, by: 4).map { i -> String in
            let start = prefix.index(prefix.startIndex, offsetBy: i)
            let end = prefix.index(start, offsetBy: min(4, prefix.count - i))
            return String(prefix[start..<end])
        }.joined(separator: " ")
    }

    /// Short fingerprint computed from a pre-computed full hex fingerprint string.
    static func shortFingerprint(from fullFingerprint: String) -> String {
        let prefix = String(fullFingerprint.prefix(16))
        return stride(from: 0, to: prefix.count, by: 4).map { i -> String in
            let start = prefix.index(prefix.startIndex, offsetBy: i)
            let end = prefix.index(start, offsetBy: min(4, prefix.count - i))
            return String(prefix[start..<end])
        }.joined(separator: " ")
    }

    // MARK: - Persistence

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Vibe/trusted-publishers.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([PublisherEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard persistent else { return }
        let dir = Self.storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
