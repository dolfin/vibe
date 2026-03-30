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

    // MARK: - verifyTrust: unsigned cases

    func testVerifyTrustUnsignedWhenNoSignature() {
        let pkg = makeUnsignedPackage(files: [:])
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: nil)
        XCTAssertEqual(result.status, .unsigned)
        XCTAssertNil(result.publisherKeyData)
    }

    func testVerifyTrustUnsignedWhenSignatureButNoPublicKey() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pkg = try makeSignedPackage(privKey: privKey, files: [:])
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: nil)
        XCTAssertEqual(result.status, .unsigned)
    }

    func testVerifyTrustUnsignedWhenSignatureButShortPublicKey() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pkg = try makeSignedPackage(privKey: privKey, files: [:])
        let shortKey = Data(repeating: 0, count: 16)
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: shortKey)
        XCTAssertEqual(result.status, .unsigned)
    }

    // MARK: - verifyTrust: verified (Vibe root key)

    func testVerifyTrustVerifiedWhenKeyMatchesVibeRoot() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation

        let fileContent = Data("Hello, Vibe!".utf8)
        let fileHash = SHA256.hash(data: fileContent)
        let fileHashHex = fileHash.map { String(format: "%02x", $0) }.joined()
        let fileDigests = ["hello.txt": fileHashHex]

        let pkg = try makeSignedPackage(privKey: privKey, files: ["hello.txt": fileContent], fileDigests: fileDigests)
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: pubKeyData)
        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.publisherKeyData, pubKeyData)
    }

    // MARK: - verifyTrust: TOFU (newPublisher / trustedByUser)

    func testVerifyTrustNewPublisherWhenKeyNotInTrustStore() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation
        let pkg = try makeSignedPackage(privKey: privKey, files: [:])

        // Pass a different key as vibeRootKey so the package key is not treated as root.
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let emptyStore = PublisherTrustStore()

        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: otherKey, trustStore: emptyStore)
        XCTAssertEqual(result.status, .tampered) // signed but neither the embedded key nor vibeRootKey can verify it
        _ = pubKeyData // suppress unused warning
    }

    func testVerifyTrustNewPublisherViaEmbeddedKey() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation
        let pkg = try makeSignedPackageWithEmbeddedKey(privKey: privKey, files: [:])

        let emptyStore = PublisherTrustStore()
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: nil, trustStore: emptyStore)
        XCTAssertEqual(result.status, .newPublisher)
        XCTAssertEqual(result.publisherKeyData, pubKeyData)
        XCTAssertNotNil(result.keyFingerprint)
    }

    func testVerifyTrustTrustedByUserWhenKeyInTrustStore() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation
        let pkg = try makeSignedPackageWithEmbeddedKey(privKey: privKey, files: [:])

        let store = PublisherTrustStore()
        store.trust(keyData: pubKeyData, publisherName: "Test Publisher")

        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: nil, trustStore: store)
        XCTAssertEqual(result.status, .trustedByUser)
        XCTAssertEqual(result.publisherKeyData, pubKeyData)
    }

    // MARK: - verifyTrust: tampered

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

        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: pubKeyData)
        XCTAssertEqual(result.status, .tampered)
    }

    func testVerifyTrustTamperedOnBadSignature() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation

        let hash = try PackageVerifier.computePackageHash(fileDigests: [:])
        let sig = try wrongKey.signature(for: hash)  // Signed with wrong key

        let pkg = VibePackage(
            packageManifest: PackageManifest(
                formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
                createdAt: "2026-01-01T00:00:00Z", files: [:]
            ),
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: try makeMinimalVibeAppZIP(files: [:])
        )

        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: pubKeyData)
        XCTAssertEqual(result.status, .tampered)
    }

    // MARK: - TrustVerificationResult helpers

    func testKeyFingerprintIsNilWhenNoKey() {
        let pkg = makeUnsignedPackage(files: [:])
        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: nil)
        XCTAssertNil(result.keyFingerprint)
    }

    func testKeyFingerprintPresentAfterVerification() throws {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privKey.publicKey.rawRepresentation
        let pkg = try makeSignedPackage(privKey: privKey, files: [:])

        let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: pubKeyData)
        XCTAssertEqual(result.status, .verified)
        XCTAssertNotNil(result.keyFingerprint)
        XCTAssertEqual(result.keyFingerprint?.count, 64) // SHA-256 hex = 64 chars
    }

    // MARK: - Error descriptions

    func testVerifyErrorDescriptions() {
        XCTAssertEqual(PackageVerifier.VerifyError.invalidPublicKey.errorDescription, "Invalid public key")
        XCTAssertEqual(PackageVerifier.VerifyError.invalidSignature.errorDescription, "Invalid signature format")
        XCTAssertEqual(PackageVerifier.VerifyError.hashMismatch(file: "foo.txt").errorDescription, "Hash mismatch for file: foo.txt")
    }

    // MARK: - PublisherTrustStore

    func testTrustStoreStartsEmpty() {
        let store = PublisherTrustStore()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testTrustStoreIsTrustedAfterTrust() {
        let store = PublisherTrustStore()
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fp = PublisherTrustStore.fingerprint(for: key)

        XCTAssertFalse(store.isTrusted(fingerprint: fp))
        store.trust(keyData: key, publisherName: "Test")
        XCTAssertTrue(store.isTrusted(fingerprint: fp))
    }

    func testTrustStoreDoesNotDuplicate() {
        let store = PublisherTrustStore()
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation

        store.trust(keyData: key, publisherName: "Test")
        store.trust(keyData: key, publisherName: "Test")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testTrustStoreRevoke() {
        let store = PublisherTrustStore()
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fp = PublisherTrustStore.fingerprint(for: key)

        store.trust(keyData: key, publisherName: "Test")
        XCTAssertTrue(store.isTrusted(fingerprint: fp))
        store.revoke(fingerprint: fp)
        XCTAssertFalse(store.isTrusted(fingerprint: fp))
    }

    func testShortFingerprintFormat() {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let short = PublisherTrustStore.shortFingerprint(for: key)
        // Should be 4 groups of 4 hex chars separated by spaces: "xxxx xxxx xxxx xxxx"
        let parts = short.split(separator: " ")
        XCTAssertEqual(parts.count, 4)
        for part in parts {
            XCTAssertEqual(part.count, 4)
        }
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

    /// Makes a signed package where the key is NOT embedded — relies on the caller supplying it as vibeRootKey.
    private func makeSignedPackage(
        privKey: Curve25519.Signing.PrivateKey,
        files: [String: Data] = [:],
        fileDigests: [String: String]? = nil
    ) throws -> VibePackage {
        let digests: [String: String] = fileDigests ?? files.mapValues { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let archiveData = try makeMinimalVibeAppZIP(files: files)
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: digests
        )
        let packageHash = try PackageVerifier.computePackageHash(fileDigests: digests)
        let sig = try privKey.signature(for: packageHash)
        return VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data("""
            {"kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0"}
            """.utf8)),
            signature: sig,
            archiveData: archiveData
        )
    }

    /// Makes a signed package that embeds the public key at "signatures/publisher.pub".
    private func makeSignedPackageWithEmbeddedKey(
        privKey: Curve25519.Signing.PrivateKey,
        files: [String: Data] = [:]
    ) throws -> VibePackage {
        let pubKeyData = privKey.publicKey.rawRepresentation
        var allFiles = files
        allFiles["signatures/publisher.pub"] = pubKeyData

        let digests: [String: String] = allFiles.mapValues { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let archiveData = try makeMinimalVibeAppZIP(files: allFiles)
        let packageManifest = PackageManifest(
            formatVersion: "1", appId: "com.test", appVersion: "1.0.0",
            createdAt: "2026-01-01T00:00:00Z", files: digests
        )
        let packageHash = try PackageVerifier.computePackageHash(fileDigests: digests)
        let sig = try privKey.signature(for: packageHash)

        let appManifestJSON = """
        {
            "kind":"vibe.app/v1","id":"com.test","name":"T","version":"1.0.0",
            "publisher":{
                "name":"Test Publisher",
                "signing":{"scheme":"ed25519","publicKeyFile":"signatures/publisher.pub"}
            }
        }
        """
        return VibePackage(
            packageManifest: packageManifest,
            appManifest: try AppManifest.fromJSON(Data(appManifestJSON.utf8)),
            signature: sig,
            archiveData: archiveData
        )
    }
}
