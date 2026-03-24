import XCTest
import ZIPFoundation
@testable import VibeHost

final class PackageDecryptionTests: XCTestCase {

    // MARK: - isEncrypted

    func testIsEncryptedFalseForPlainZIP() throws {
        let plainData = try makeSimpleZIP(files: ["file.txt": Data("hello".utf8)])
        XCTAssertFalse(PackageDecryption.isEncrypted(plainData))
    }

    func testIsEncryptedFalseForNonZIP() {
        XCTAssertFalse(PackageDecryption.isEncrypted(Data("not a zip".utf8)))
    }

    func testIsEncryptedFalseForEmptyData() {
        XCTAssertFalse(PackageDecryption.isEncrypted(Data()))
    }

    func testIsEncryptedTrueAfterEncrypt() throws {
        let plainData = Data("my app payload".utf8)
        let encrypted = try PackageDecryption.encrypt(plainData, password: "test123")
        XCTAssertTrue(PackageDecryption.isEncrypted(encrypted))
    }

    func testIsEncryptedFalseForZIPWithoutEncryptionJson() throws {
        // A ZIP that has other files but not _vibe_encryption.json
        let archiveData = try makeSimpleZIP(files: [
            "app.txt": Data("app".utf8),
            "_vibe_package_manifest.json": Data("manifest".utf8),
        ])
        XCTAssertFalse(PackageDecryption.isEncrypted(archiveData))
    }

    // MARK: - encrypt / decrypt round-trip

    func testEncryptDecryptRoundTrip() throws {
        let original = Data("Secret payload data 🔐".utf8)
        let password = "correct-horse-battery-staple"
        let encrypted = try PackageDecryption.encrypt(original, password: password)
        let decrypted = try PackageDecryption.decrypt(encrypted, password: password)
        XCTAssertEqual(decrypted, original)
    }

    func testEncryptDecryptRoundTripWithBinaryData() throws {
        let original = Data((0..<256).map { UInt8($0) })
        let password = "p@ssw0rd!"
        let encrypted = try PackageDecryption.encrypt(original, password: password)
        let decrypted = try PackageDecryption.decrypt(encrypted, password: password)
        XCTAssertEqual(decrypted, original)
    }

    func testEncryptProducesEncryptedOutput() throws {
        let data = Data("plaintext".utf8)
        let encrypted = try PackageDecryption.encrypt(data, password: "pw")
        // Encrypted output should not equal plaintext
        XCTAssertNotEqual(encrypted, data)
        // Must be a valid ZIP with encryption marker
        XCTAssertTrue(PackageDecryption.isEncrypted(encrypted))
    }

    func testEncryptProducesDifferentOutputEachTime() throws {
        // Each call uses fresh random salt + nonce
        let data = Data("same data".utf8)
        let password = "same password"
        let enc1 = try PackageDecryption.encrypt(data, password: password)
        let enc2 = try PackageDecryption.encrypt(data, password: password)
        XCTAssertNotEqual(enc1, enc2, "Each encryption should produce different ciphertext")
    }

    // MARK: - decrypt — error cases

    func testDecryptWrongPassword() throws {
        let original = Data("secret".utf8)
        let encrypted = try PackageDecryption.encrypt(original, password: "correct")
        XCTAssertThrowsError(try PackageDecryption.decrypt(encrypted, password: "wrong")) { error in
            guard case PackageDecryption.DecryptError.wrongPassword = error else {
                XCTFail("Expected wrongPassword, got \(error)")
                return
            }
        }
    }

    func testDecryptMissingEncryptionMetadata() throws {
        // A plain ZIP without _vibe_encryption.json
        let plainZIP = try makeSimpleZIP(files: ["_vibe_encrypted_payload": Data("payload".utf8)])
        XCTAssertThrowsError(try PackageDecryption.decrypt(plainZIP, password: "pw")) { error in
            guard case PackageDecryption.DecryptError.missingEncryptionMetadata = error else {
                XCTFail("Expected missingEncryptionMetadata, got \(error)")
                return
            }
        }
    }

    func testDecryptMissingPayload() throws {
        // ZIP with _vibe_encryption.json but no _vibe_encrypted_payload
        let archive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        let metaJSON = """
        {
          "version": 1,
          "cipher": "aes-256-gcm",
          "kdf": "argon2id",
          "kdf_params": {
            "m_cost": 65536,
            "t_cost": 3,
            "p_cost": 4,
            "salt": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
          },
          "nonce": "010203040506070809101112"
        }
        """.data(using: .utf8)!
        try addEntry(to: archive, name: "_vibe_encryption.json", data: metaJSON)
        let archiveData = archive.data!
        XCTAssertThrowsError(try PackageDecryption.decrypt(archiveData, password: "pw")) { error in
            guard case PackageDecryption.DecryptError.missingPayload = error else {
                XCTFail("Expected missingPayload, got \(error)")
                return
            }
        }
    }

    // MARK: - EncryptionMetadata Codable

    func testEncryptionMetadataCodableRoundTrip() throws {
        let meta = EncryptionMetadata(
            version: 1,
            cipher: "aes-256-gcm",
            kdf: "argon2id",
            kdfParams: EncryptionMetadata.KdfParams(
                mCost: 65536,
                tCost: 3,
                pCost: 4,
                salt: "deadbeefdeadbeef"
            ),
            nonce: "aabbccddeeff0011"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(meta)
        let decoded = try JSONDecoder().decode(EncryptionMetadata.self, from: data)
        XCTAssertEqual(decoded.version, meta.version)
        XCTAssertEqual(decoded.cipher, meta.cipher)
        XCTAssertEqual(decoded.kdf, meta.kdf)
        XCTAssertEqual(decoded.kdfParams.mCost, meta.kdfParams.mCost)
        XCTAssertEqual(decoded.kdfParams.tCost, meta.kdfParams.tCost)
        XCTAssertEqual(decoded.kdfParams.pCost, meta.kdfParams.pCost)
        XCTAssertEqual(decoded.kdfParams.salt, meta.kdfParams.salt)
        XCTAssertEqual(decoded.nonce, meta.nonce)
    }

    func testEncryptionMetadataUsesSnakeCaseKdfParams() throws {
        let meta = EncryptionMetadata(
            version: 1, cipher: "aes-256-gcm", kdf: "argon2id",
            kdfParams: EncryptionMetadata.KdfParams(mCost: 1, tCost: 2, pCost: 3, salt: "aa"),
            nonce: "bb"
        )
        let data = try JSONEncoder().encode(meta)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let kdfParamsJson = json["kdf_params"] as? [String: Any]
        XCTAssertNotNil(kdfParamsJson?["m_cost"])
        XCTAssertNotNil(kdfParamsJson?["t_cost"])
        XCTAssertNotNil(kdfParamsJson?["p_cost"])
        XCTAssertNil(kdfParamsJson?["mCost"])
    }

    // MARK: - Error descriptions

    func testDecryptErrorDescriptions() {
        let cases: [(PackageDecryption.DecryptError, String)] = [
            (.missingEncryptionMetadata, "Encrypted package is missing _vibe_encryption.json"),
            (.missingPayload, "Encrypted package is missing _vibe_encrypted_payload"),
            (.invalidMetadata("bad hex"), "Invalid encryption metadata: bad hex"),
            (.wrongPassword, "Wrong password or corrupted encrypted package"),
            (.cancelled, "Password entry was cancelled"),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }
}
