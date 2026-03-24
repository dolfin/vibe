import XCTest
import CryptoKit
@testable import VibeHost

final class PackageVerifierTests: XCTestCase {

    // MARK: - computePackageHash

    func testComputePackageHashEmptyDict() throws {
        let hash = try PackageVerifier.computePackageHash(fileDigests: [:])
        // SHA-256("{}")
        let expected = SHA256.hash(data: Data("{}".utf8))
        let expectedHex = expected.map { String(format: "%02x", $0) }.joined()
        let actualHex = hash.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualHex, expectedHex)
    }

    func testComputePackageHashSingleEntry() throws {
        let digests = ["only.txt": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"]
        let hash1 = try PackageVerifier.computePackageHash(fileDigests: digests)
        let hash2 = try PackageVerifier.computePackageHash(fileDigests: digests)
        XCTAssertEqual(hash1, hash2, "Hash must be deterministic")
    }

    func testComputePackageHashIsDeterministic() throws {
        let digests: [String: String] = [
            "z_last.txt": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "a_first.txt": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "m_middle.txt": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        ]
        let hash1 = try PackageVerifier.computePackageHash(fileDigests: digests)
        let hash2 = try PackageVerifier.computePackageHash(fileDigests: digests)
        XCTAssertEqual(hash1, hash2)
    }

    func testComputePackageHashSortedByKey() throws {
        // Same files, different insertion order — must produce same hash (BTreeMap-equivalent)
        let digests1: [String: String] = [
            "b.txt": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "a.txt": "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7",
        ]
        // Swift Dictionary doesn't guarantee order, but computePackageHash sorts keys
        // So both dicts should produce identical hashes regardless of insertion order
        let hash1 = try PackageVerifier.computePackageHash(fileDigests: digests1)
        let digests2: [String: String] = [
            "a.txt": "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7",
            "b.txt": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        ]
        let hash2 = try PackageVerifier.computePackageHash(fileDigests: digests2)
        XCTAssertEqual(hash1, hash2)
    }

    func testComputePackageHashReturns32Bytes() throws {
        let hash = try PackageVerifier.computePackageHash(fileDigests: ["f.txt": String(repeating: "a", count: 64)])
        XCTAssertEqual(hash.count, 32)
    }

    // MARK: - verifySignature

    func testVerifySignatureInvalidPublicKeyLength() throws {
        let shortKey = Data(repeating: 0, count: 16)  // 16 bytes instead of 32
        let sig = Data(repeating: 0, count: 64)
        let data = Data("test".utf8)
        XCTAssertThrowsError(try PackageVerifier.verifySignature(sig, over: data, publicKey: shortKey)) { error in
            guard case PackageVerifier.VerifyError.invalidPublicKey = error else {
                XCTFail("Expected invalidPublicKey, got \(error)")
                return
            }
        }
    }

    func testVerifySignatureInvalidSignatureLength() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKey = privKey.publicKey.rawRepresentation
        let shortSig = Data(repeating: 0, count: 32)  // 32 bytes instead of 64
        let data = Data("test".utf8)
        XCTAssertThrowsError(try PackageVerifier.verifySignature(shortSig, over: data, publicKey: pubKey)) { error in
            guard case PackageVerifier.VerifyError.invalidSignature = error else {
                XCTFail("Expected invalidSignature, got \(error)")
                return
            }
        }
    }

    func testVerifySignatureValidKeyPair() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation
        let data = Data("hello, world".utf8)
        let sigData = try privKey.signature(for: data)
        XCTAssertNoThrow(try PackageVerifier.verifySignature(sigData, over: data, publicKey: pubKeyData))
    }

    func testVerifySignatureWrongKey() throws {
        let privKey1 = Curve25519.Signing.PrivateKey()
        let privKey2 = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey2.publicKey.rawRepresentation  // Key 2's pubkey
        let data = Data("test message".utf8)
        let sigData = try privKey1.signature(for: data)  // Signed with key 1
        XCTAssertThrowsError(try PackageVerifier.verifySignature(sigData, over: data, publicKey: pubKeyData)) { error in
            guard case PackageVerifier.VerifyError.invalidSignature = error else {
                XCTFail("Expected invalidSignature, got \(error)")
                return
            }
        }
    }

    func testVerifySignatureWrongData() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation
        let original = Data("original data".utf8)
        let tampered = Data("tampered data".utf8)
        let sigData = try privKey.signature(for: original)
        XCTAssertThrowsError(try PackageVerifier.verifySignature(sigData, over: tampered, publicKey: pubKeyData)) { error in
            guard case PackageVerifier.VerifyError.invalidSignature = error else {
                XCTFail("Expected invalidSignature, got \(error)")
                return
            }
        }
    }

    // MARK: - verifyTrust

    func testVerifyTrustUnsignedWhenNoSignature() {
        let pkg = makeUnsignedPackage(files: [:])
        XCTAssertEqual(PackageVerifier.verifyTrust(package: pkg, publicKey: nil), .unsigned)
    }

    func testVerifyTrustUnsignedWhenSignatureButNoPublicKey() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let archiveData = try makeMinimalVibeAppZIP(files: [:])
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: [:]
        )
        let hash = try PackageVerifier.computePackageHash(fileDigests: [:])
        let sig = try privKey.signature(for: hash)
        let pkg = VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: archiveData
        )
        XCTAssertEqual(PackageVerifier.verifyTrust(package: pkg, publicKey: nil), .unsigned)
    }

    func testVerifyTrustUnsignedWhenSignatureButShortPublicKey() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let archiveData = try makeMinimalVibeAppZIP(files: [:])
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: [:]
        )
        let hash = try PackageVerifier.computePackageHash(fileDigests: [:])
        let sig = try privKey.signature(for: hash)
        let pkg = VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: archiveData
        )
        let shortKey = Data(repeating: 0, count: 16)
        XCTAssertEqual(PackageVerifier.verifyTrust(package: pkg, publicKey: shortKey), .unsigned)
    }

    func testVerifyTrustVerified() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation

        // Create a file with known content
        let fileContent = Data("Hello, Vibe!".utf8)
        let fileHash = SHA256.hash(data: fileContent)
        let fileHashHex = fileHash.map { String(format: "%02x", $0) }.joined()
        let fileDigests = ["hello.txt": fileHashHex]

        // Build archive with that file
        let archiveData = try makeMinimalVibeAppZIP(files: ["hello.txt": fileContent])

        // Build package manifest
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: fileDigests
        )

        // Sign the package hash
        let packageHash = try PackageVerifier.computePackageHash(fileDigests: fileDigests)
        let sig = try privKey.signature(for: packageHash)

        let pkg = VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: archiveData
        )

        XCTAssertEqual(PackageVerifier.verifyTrust(package: pkg, publicKey: pubKeyData), .verified)
    }

    func testVerifyTrustTamperedWhenFileHashMismatch() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation

        let originalContent = Data("Original content".utf8)
        let tamperedContent = Data("Tampered content!!".utf8)
        let originalHash = SHA256.hash(data: originalContent)
        let originalHashHex = originalHash.map { String(format: "%02x", $0) }.joined()
        let fileDigests = ["file.txt": originalHashHex]

        // Archive has tampered content but manifest records original hash
        let archiveData = try makeMinimalVibeAppZIP(files: ["file.txt": tamperedContent])
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: fileDigests
        )

        // Sign the original package hash (correctly signed, but content is tampered)
        let packageHash = try PackageVerifier.computePackageHash(fileDigests: fileDigests)
        let sig = try privKey.signature(for: packageHash)

        let pkg = VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: archiveData
        )

        XCTAssertEqual(PackageVerifier.verifyTrust(package: pkg, publicKey: pubKeyData), .tampered)
    }

    func testVerifyTrustTamperedOnBadSignature() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation

        let archiveData = try makeMinimalVibeAppZIP(files: [:])
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: [:]
        )
        let hash = try PackageVerifier.computePackageHash(fileDigests: [:])
        // Sign with wrong key
        let sig = try wrongKey.signature(for: hash)

        let pkg = VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: archiveData
        )

        XCTAssertEqual(PackageVerifier.verifyTrust(package: pkg, publicKey: pubKeyData), .tampered)
    }

    // MARK: - Error descriptions

    func testVerifyErrorDescriptions() {
        XCTAssertEqual(PackageVerifier.VerifyError.invalidPublicKey.errorDescription, "Invalid public key")
        XCTAssertEqual(PackageVerifier.VerifyError.invalidSignature.errorDescription, "Invalid signature format")
        XCTAssertEqual(PackageVerifier.VerifyError.hashMismatch(file: "foo.txt").errorDescription, "Hash mismatch for file: foo.txt")
    }

    // MARK: - Helpers

    private func makeUnsignedPackage(files: [String: String]) -> VibePackage {
        let manifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: files
        )
        let appManifest = try! AppManifest.fromJSON(Data("""
        {"kind":"vibe.app/v1","id":"com.test","name":"Test","version":"1.0.0"}
        """.utf8))
        return VibePackage(
            packageManifest: manifest,
            appManifest: appManifest,
            signature: nil,
            archiveData: Data()
        )
    }
}
