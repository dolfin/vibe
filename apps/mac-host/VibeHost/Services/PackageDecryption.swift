import AppKit
import Argon2Swift
import CryptoKit
import Foundation
import ZIPFoundation

// MARK: - Encryption metadata (mirrors Rust EncryptionMetadata)

struct EncryptionMetadata: Codable {
    let version: Int
    let cipher: String
    let kdf: String
    let kdfParams: KdfParams
    let nonce: String

    struct KdfParams: Codable {
        let mCost: UInt32
        let tCost: UInt32
        let pCost: UInt32
        let salt: String

        enum CodingKeys: String, CodingKey {
            case mCost = "m_cost"
            case tCost = "t_cost"
            case pCost = "p_cost"
            case salt
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case cipher
        case kdf
        case kdfParams = "kdf_params"
        case nonce
    }
}

// MARK: - Per-document encryption context

/// Holds the session password — used to re-encrypt on every save.
struct EncryptionContext {
    let password: String
}

// MARK: - PackageDecryption

enum PackageDecryption {
    enum DecryptError: LocalizedError {
        case missingEncryptionMetadata
        case missingPayload
        case invalidMetadata(String)
        case wrongPassword
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingEncryptionMetadata:
                return "Encrypted package is missing _vibe_encryption.json"
            case .missingPayload:
                return "Encrypted package is missing _vibe_encrypted_payload"
            case .invalidMetadata(let d):
                return "Invalid encryption metadata: \(d)"
            case .wrongPassword:
                return "Wrong password or corrupted encrypted package"
            case .cancelled:
                return "Password entry was cancelled"
            }
        }
    }

    // MARK: - Detection

    /// Returns true if `data` is an encrypted outer .vibeapp ZIP.
    static func isEncrypted(_ data: Data) -> Bool {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            return false
        }
        return archive["_vibe_encryption.json"] != nil
    }

    // MARK: - Decrypt

    /// Decrypt an encrypted .vibeapp, returning the inner plaintext ZIP bytes.
    static func decrypt(_ data: Data, password: String) throws -> Data {
        let archive = try Archive(data: data, accessMode: .read, pathEncoding: nil)

        guard let metaEntry = archive["_vibe_encryption.json"] else {
            throw DecryptError.missingEncryptionMetadata
        }
        var metaData = Data()
        _ = try archive.extract(metaEntry) { chunk in metaData.append(chunk) }

        let meta: EncryptionMetadata
        do {
            meta = try JSONDecoder().decode(EncryptionMetadata.self, from: metaData)
        } catch {
            throw DecryptError.invalidMetadata(error.localizedDescription)
        }

        guard let payloadEntry = archive["_vibe_encrypted_payload"] else {
            throw DecryptError.missingPayload
        }
        var payload = Data()
        _ = try archive.extract(payloadEntry) { chunk in payload.append(chunk) }

        let keyData = try deriveKey(password: password, meta: meta)
        let symmetricKey = SymmetricKey(data: keyData)

        let nonceData = try hexDecode(meta.nonce, expectedLength: 12)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        // Rust aes-gcm format: payload = ciphertext + 16-byte GCM tag
        guard payload.count >= 16 else { throw DecryptError.wrongPassword }
        let tag = payload.suffix(16)
        let ciphertext = payload.dropLast(16)

        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw DecryptError.wrongPassword
        }
    }

    // MARK: - Encrypt

    /// Encrypt inner ZIP bytes into an encrypted outer .vibeapp ZIP.
    /// Generates fresh random salt + nonce on each call.
    static func encrypt(_ data: Data, password: String) throws -> Data {
        var saltBytes = [UInt8](repeating: 0, count: 32)
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &saltBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, 12, &nonceBytes)

        let meta = EncryptionMetadata(
            version: 1,
            cipher: "aes-256-gcm",
            kdf: "argon2id",
            kdfParams: EncryptionMetadata.KdfParams(
                mCost: 65536, tCost: 3, pCost: 4,
                salt: hexEncode(saltBytes)
            ),
            nonce: hexEncode(nonceBytes)
        )

        let keyData = try deriveKey(password: password, meta: meta)
        let symmetricKey = SymmetricKey(data: keyData)
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let box = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)
        // Rust format: ciphertext + tag (nonce stored separately in JSON)
        let payload = box.ciphertext + box.tag

        let outerArchive = try Archive(data: Data(), accessMode: .create, pathEncoding: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaJson = try encoder.encode(meta)

        // Normalise to index-0 Data so Range<Int> subscripting is safe inside the provider closures.
        let metaCapture = Data(metaJson)
        try outerArchive.addEntry(
            with: "_vibe_encryption.json",
            type: .file,
            uncompressedSize: Int64(metaCapture.count),
            compressionMethod: .none,
            provider: { pos, size in
                Data(metaCapture.dropFirst(Int(pos)).prefix(size))
            }
        )
        let payloadCapture = Data(payload)
        try outerArchive.addEntry(
            with: "_vibe_encrypted_payload",
            type: .file,
            uncompressedSize: Int64(payloadCapture.count),
            compressionMethod: .none,
            provider: { pos, size in
                Data(payloadCapture.dropFirst(Int(pos)).prefix(size))
            }
        )

        guard let result = outerArchive.data else {
            throw DecryptError.missingPayload
        }
        return result
    }

    // MARK: - Password prompt

    /// Show a blocking NSAlert with a secure text field to collect the password.
    /// Safe to call from any thread — dispatches to main if needed.
    /// Returns nil if the user cancels or enters an empty password.
    static func promptPassword(forPackage name: String = "this package") -> String? {
        var result: String?
        let block = {
            let alert = NSAlert()
            alert.messageText = "Encrypted Package"
            alert.informativeText = "\"\(name)\" is password-protected. Enter the password to open it."
            alert.alertStyle = .informational

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Password"
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field

            let response = alert.runModal()
            let pw = field.stringValue
            result = (response == .alertFirstButtonReturn && !pw.isEmpty) ? pw : nil
        }

        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
        return result
    }

    // MARK: - Private helpers

    private static func deriveKey(password: String, meta: EncryptionMetadata) throws -> Data {
        let saltData = try hexDecode(meta.kdfParams.salt, expectedLength: 32)
        let result = try Argon2Swift.hashPasswordBytes(
            password: Data(password.utf8),
            salt: Salt(bytes: saltData),
            iterations: Int(meta.kdfParams.tCost),
            memory: Int(meta.kdfParams.mCost),
            parallelism: Int(meta.kdfParams.pCost),
            length: 32,
            type: .id,
            version: .V13
        )
        return result.hashData()
    }

    private static func hexDecode(_ hex: String, expectedLength: Int) throws -> Data {
        guard hex.count == expectedLength * 2 else {
            throw DecryptError.invalidMetadata(
                "expected \(expectedLength * 2) hex chars, got \(hex.count)"
            )
        }
        var data = Data(capacity: expectedLength)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else {
                throw DecryptError.invalidMetadata("invalid hex character")
            }
            data.append(byte)
            i = j
        }
        return data
    }

    private static func hexEncode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
