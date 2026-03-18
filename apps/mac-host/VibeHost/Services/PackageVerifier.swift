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

    /// Determine trust status for a package.
    static func verifyTrust(package pkg: VibePackage, publicKey: Data?) -> TrustStatus {
        guard let sigData = pkg.signature else {
            return .unsigned
        }

        guard let pubKeyData = publicKey, pubKeyData.count == 32 else {
            return .unsigned // Cannot verify without a valid key — treat as unsigned
        }

        do {
            let packageHash = try computePackageHash(fileDigests: pkg.packageManifest.files)
            try verifySignature(sigData, over: packageHash, publicKey: pubKeyData)

            // Also verify individual file hashes
            for (filePath, expectedHex) in pkg.packageManifest.files {
                if let fileData = try PackageExtractor.extractFile(named: filePath, from: pkg.archiveData) {
                    let actualHash = SHA256.hash(data: fileData)
                    let actualHex = actualHash.map { String(format: "%02x", $0) }.joined()
                    if actualHex != expectedHex {
                        return .tampered
                    }
                }
            }

            return .verified
        } catch {
            return .tampered
        }
    }

    /// Compute the package hash from file digests, matching the Rust implementation.
    ///
    /// Rust's `serde_json` serializes `BTreeMap<String, [u8; 32]>` as:
    /// `{"key":[n1,n2,...,n32],...}` with keys sorted alphabetically, no whitespace.
    /// Each `[u8; 32]` is serialized as a JSON array of integers.
    static func computePackageHash(fileDigests: [String: String]) throws -> Data {
        // Convert hex strings to byte arrays, then build the same JSON as Rust
        let sortedKeys = fileDigests.keys.sorted()

        var json = "{"
        for (index, key) in sortedKeys.enumerated() {
            guard let hexString = fileDigests[key] else { continue }
            let bytes = hexToBytes(hexString)

            // Key
            json += "\"\(key)\":"

            // Value: array of integers matching serde's [u8; 32] serialization
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
