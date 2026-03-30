import Foundation
import CryptoKit

/// Verifies .vibeapp package integrity and signatures.
enum PackageVerifier {
    enum VerifyError: LocalizedError {
        case invalidPublicKey
        case invalidSignature
        case hashMismatch(file: String)

        var errorDescription: String? {
            switch self {
            case .invalidPublicKey: "Invalid public key"
            case .invalidSignature: "Invalid signature format"
            case .hashMismatch(let file): "Hash mismatch for file: \(file)"
            }
        }
    }

    /// Result of a trust verification, carrying resolved key data for TOFU actions.
    struct TrustVerificationResult {
        let status: TrustStatus
        /// The 32-byte Ed25519 public key used for verification (nil if unsigned/unverifiable).
        let publisherKeyData: Data?
        /// Publisher name from the app manifest.
        let publisherName: String?

        /// Full SHA-256 hex fingerprint of `publisherKeyData`, or nil if no key.
        var keyFingerprint: String? {
            publisherKeyData.map { PublisherTrustStore.fingerprint(for: $0) }
        }
    }

    /// Determine trust status for a package.
    ///
    /// **Key resolution order:**
    /// 1. Extract the publisher public key embedded in the package via
    ///    `publisher.signing.publicKeyFile` in the app manifest.
    /// 2. Fall back to `vibeRootKey` (the key bundled with the Vibe app itself).
    ///
    /// **Trust classification after a valid signature:**
    /// - Key matches `vibeRootKey` → `.verified`
    /// - Key fingerprint is in `trustStore` → `.trustedByUser`
    /// - Key is unknown → `.newPublisher` (user will be prompted)
    static func verifyTrust(
        package pkg: VibePackage,
        vibeRootKey: Data?,
        trustStore: PublisherTrustStore = .shared
    ) -> TrustVerificationResult {
        let publisherName = pkg.appManifest.publisher?.name

        guard let sigData = pkg.signature else {
            return TrustVerificationResult(status: .unsigned, publisherKeyData: nil, publisherName: publisherName)
        }

        // 1. Try to extract a public key embedded inside the package.
        let embeddedKeyData: Data? = {
            guard let keyPath = pkg.appManifest.publisher?.signing?.publicKeyFile,
                  let data = try? PackageExtractor.extractFile(named: keyPath, from: pkg.archiveData),
                  data.count == 32 else { return nil }
            return data
        }()

        // 2. Prefer embedded key; fall back to the Vibe root key.
        let keyData = embeddedKeyData ?? vibeRootKey
        guard let keyData, keyData.count == 32 else {
            return TrustVerificationResult(status: .unsigned, publisherKeyData: nil, publisherName: publisherName)
        }

        // Verify Ed25519 signature and individual file hashes.
        do {
            let packageHash = try computePackageHash(fileDigests: pkg.packageManifest.files)
            try verifySignature(sigData, over: packageHash, publicKey: keyData)

            for (filePath, expectedHex) in pkg.packageManifest.files {
                if let fileData = try PackageExtractor.extractFile(named: filePath, from: pkg.archiveData) {
                    let actualHash = SHA256.hash(data: fileData)
                    let actualHex = actualHash.map { String(format: "%02x", $0) }.joined()
                    if actualHex != expectedHex {
                        return TrustVerificationResult(status: .tampered, publisherKeyData: keyData, publisherName: publisherName)
                    }
                }
            }
        } catch {
            return TrustVerificationResult(status: .tampered, publisherKeyData: keyData, publisherName: publisherName)
        }

        // Classify trust level.
        if let vibeRootKey, keyData == vibeRootKey {
            return TrustVerificationResult(status: .verified, publisherKeyData: keyData, publisherName: publisherName)
        }

        let fingerprint = PublisherTrustStore.fingerprint(for: keyData)
        let status: TrustStatus = trustStore.isTrusted(fingerprint: fingerprint) ? .trustedByUser : .newPublisher
        return TrustVerificationResult(status: status, publisherKeyData: keyData, publisherName: publisherName)
    }

    /// Compute the package hash from file digests, matching the Rust implementation.
    ///
    /// Rust's `serde_json` serializes `BTreeMap<String, [u8; 32]>` as:
    /// `{"key":[n1,n2,...,n32],...}` with keys sorted alphabetically, no whitespace.
    /// Each `[u8; 32]` is serialized as a JSON array of integers.
    static func computePackageHash(fileDigests: [String: String]) throws -> Data {
        let sortedKeys = fileDigests.keys.sorted()

        var json = "{"
        for (index, key) in sortedKeys.enumerated() {
            guard let hexString = fileDigests[key] else { continue }
            let bytes = hexToBytes(hexString)

            json += "\"\(key)\":"
            json += "["
            json += bytes.map { String($0) }.joined(separator: ",")
            json += "]"

            if index < sortedKeys.count - 1 {
                json += ","
            }
        }
        json += "}"

        let jsonData = Data(json.utf8)
        let hash = SHA256.hash(data: jsonData)
        return Data(hash)
    }

    /// Verify an Ed25519 signature.
    static func verifySignature(_ signatureData: Data, over data: Data, publicKey pubKeyData: Data) throws {
        guard pubKeyData.count == 32 else {
            throw VerifyError.invalidPublicKey
        }
        guard signatureData.count == 64 else {
            throw VerifyError.invalidSignature
        }

        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)
        guard pubKey.isValidSignature(signatureData, for: data) else {
            throw VerifyError.invalidSignature
        }
    }

    /// Convert a hex string to bytes.
    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }
}
