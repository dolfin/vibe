use std::fs;
use std::io::{Read, Write};
use std::path::Path;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use anyhow::{Context, Result};
use argon2::{Algorithm, Argon2, Params, Version};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct KdfParams {
    pub m_cost: u32,
    pub t_cost: u32,
    pub p_cost: u32,
    pub salt: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct EncryptionMetadata {
    pub version: u32,
    pub cipher: String,
    pub kdf: String,
    pub kdf_params: KdfParams,
    pub nonce: String,
}

impl EncryptionMetadata {
    pub fn salt_bytes(&self) -> Result<[u8; 32]> {
        let bytes = hex_decode_32(&self.kdf_params.salt)?;
        Ok(bytes)
    }

    pub fn nonce_bytes(&self) -> Result<[u8; 12]> {
        let bytes = hex_decode_12(&self.nonce)?;
        Ok(bytes)
    }
}

/// Argon2id key derivation (OWASP interactive profile).
pub fn derive_key(password: &[u8], meta: &EncryptionMetadata) -> Result<Zeroizing<[u8; 32]>> {
    // Validate cost parameters to prevent DoS via maliciously crafted package metadata.
    // Ceilings match the values used during encryption; a legitimate package will never exceed them.
    const MAX_M_COST: u32 = 65536; // 64 MiB
    const MAX_T_COST: u32 = 10;
    const MAX_P_COST: u32 = 8;
    if meta.kdf_params.m_cost > MAX_M_COST {
        anyhow::bail!(
            "KDF m_cost {} exceeds maximum {}",
            meta.kdf_params.m_cost,
            MAX_M_COST
        );
    }
    if meta.kdf_params.t_cost > MAX_T_COST {
        anyhow::bail!(
            "KDF t_cost {} exceeds maximum {}",
            meta.kdf_params.t_cost,
            MAX_T_COST
        );
    }
    if meta.kdf_params.p_cost > MAX_P_COST {
        anyhow::bail!(
            "KDF p_cost {} exceeds maximum {}",
            meta.kdf_params.p_cost,
            MAX_P_COST
        );
    }

    let salt = meta.salt_bytes()?;
    let params = Params::new(
        meta.kdf_params.m_cost,
        meta.kdf_params.t_cost,
        meta.kdf_params.p_cost,
        Some(32),
    )
    .map_err(|e| anyhow::anyhow!("Invalid Argon2 params: {}", e))?;

    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0u8; 32]);
    argon2
        .hash_password_into(password, &salt, key.as_mut())
        .map_err(|e| anyhow::anyhow!("Argon2 key derivation failed: {}", e))?;
    Ok(key)
}

/// Encrypt raw package bytes. Generates fresh random salt + nonce.
pub fn encrypt_package(plaintext: &[u8], password: &[u8]) -> Result<(Vec<u8>, EncryptionMetadata)> {
    let mut salt = [0u8; 32];
    let mut nonce_bytes = [0u8; 12];
    let mut rng = rand::thread_rng();
    rng.fill_bytes(&mut salt);
    rng.fill_bytes(&mut nonce_bytes);

    let meta = EncryptionMetadata {
        version: 1,
        cipher: "aes-256-gcm".to_string(),
        kdf: "argon2id".to_string(),
        kdf_params: KdfParams {
            m_cost: 65536,
            t_cost: 3,
            p_cost: 4,
            salt: hex_encode(&salt),
        },
        nonce: hex_encode(&nonce_bytes),
    };

    let key_bytes = derive_key(password, &meta)?;
    let key = Key::<Aes256Gcm>::from_slice(key_bytes.as_ref());
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| anyhow::anyhow!("AES-GCM encryption failed: {}", e))?;

    Ok((ciphertext, meta))
}

/// Decrypt raw ciphertext. Returns Err on wrong password or corruption.
pub fn decrypt_package(
    ciphertext: &[u8],
    password: &[u8],
    meta: &EncryptionMetadata,
) -> Result<Vec<u8>> {
    let key_bytes = derive_key(password, meta)?;
    let key = Key::<Aes256Gcm>::from_slice(key_bytes.as_ref());
    let cipher = Aes256Gcm::new(key);
    let nonce_bytes = meta.nonce_bytes()?;
    let nonce = Nonce::from_slice(&nonce_bytes);

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| anyhow::anyhow!("Decryption failed — wrong password or corrupted package"))
}

/// Build outer ZIP with _vibe_encryption.json + _vibe_encrypted_payload.
pub fn write_encrypted_vibeapp(
    payload: &[u8],
    meta: &EncryptionMetadata,
    dest: &Path,
) -> Result<()> {
    let meta_json =
        serde_json::to_string_pretty(meta).context("Failed to serialize encryption metadata")?;

    let file =
        fs::File::create(dest).with_context(|| format!("Failed to create '{}'", dest.display()))?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);

    zip.start_file("_vibe_encryption.json", options)?;
    zip.write_all(meta_json.as_bytes())?;

    zip.start_file("_vibe_encrypted_payload", options)?;
    zip.write_all(payload)?;

    zip.finish().context("Failed to finalize encrypted ZIP")?;
    Ok(())
}

/// Parse outer ZIP → (ciphertext, metadata).
pub fn read_encrypted_vibeapp(path: &Path) -> Result<(Vec<u8>, EncryptionMetadata)> {
    let data = fs::read(path).with_context(|| format!("Failed to read '{}'", path.display()))?;
    let cursor = std::io::Cursor::new(&data);
    let mut archive =
        zip::ZipArchive::new(cursor).context("Failed to open encrypted package as ZIP")?;

    let meta: EncryptionMetadata = {
        let mut file = archive
            .by_name("_vibe_encryption.json")
            .context("Encrypted package missing _vibe_encryption.json")?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        serde_json::from_str(&contents).context("Failed to parse _vibe_encryption.json")?
    };

    let ciphertext = {
        let mut file = archive
            .by_name("_vibe_encrypted_payload")
            .context("Encrypted package missing _vibe_encrypted_payload")?;
        let mut contents = Vec::new();
        file.read_to_end(&mut contents)?;
        contents
    };

    Ok((ciphertext, meta))
}

/// Returns true if ZIP contains _vibe_encryption.json.
pub fn is_encrypted_package(path: &Path) -> bool {
    let Ok(data) = fs::read(path) else {
        return false;
    };
    let Ok(mut archive) = zip::ZipArchive::new(std::io::Cursor::new(data)) else {
        return false;
    };
    let found = archive.by_name("_vibe_encryption.json").is_ok();
    found
}

/// Resolve password: --password > --password-file > interactive prompt.
/// Returns a `Zeroizing<String>` so the plaintext password is wiped from
/// memory as soon as the caller drops it.
pub fn resolve_password(
    password: Option<&str>,
    password_file: Option<&Path>,
    prompt: &str,
) -> Result<Zeroizing<String>> {
    if let Some(pw) = password {
        return Ok(Zeroizing::new(pw.to_string()));
    }
    if let Some(path) = password_file {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("Failed to read password file '{}'", path.display()))?;
        return Ok(Zeroizing::new(contents.trim().to_string()));
    }
    let pw = rpassword::prompt_password(prompt).context("Failed to read password interactively")?;
    Ok(Zeroizing::new(pw))
}

/// If package is encrypted, decrypt it in memory. If not, read raw bytes.
pub fn open_package(
    path: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<Vec<u8>> {
    if is_encrypted_package(path) {
        let (ciphertext, meta) = read_encrypted_vibeapp(path)?;
        let pw = resolve_password(password, password_file, "Password: ")?;
        // pw is Zeroizing<String>; pass as bytes without copying into a plain String
        let plaintext = decrypt_package(&ciphertext, pw.as_bytes(), &meta)?;
        Ok(plaintext)
    } else {
        fs::read(path).with_context(|| format!("Failed to read '{}'", path.display()))
    }
}

/// Write package: if password given, encrypt. Otherwise write raw.
pub fn save_package(
    bytes: &[u8],
    dest: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<()> {
    if password.is_some() || password_file.is_some() {
        let pw = resolve_password(password, password_file, "Password: ")?;
        // pw is Zeroizing<String>; pass as bytes without copying into a plain String
        let (ciphertext, meta) = encrypt_package(bytes, pw.as_bytes())?;
        write_encrypted_vibeapp(&ciphertext, &meta, dest)
    } else {
        fs::write(dest, bytes).with_context(|| format!("Failed to write '{}'", dest.display()))
    }
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

fn hex_decode_32(s: &str) -> Result<[u8; 32]> {
    if s.len() != 64 {
        anyhow::bail!("Expected 64 hex chars, got {}", s.len());
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)
            .with_context(|| format!("Invalid hex at position {}", i * 2))?;
    }
    Ok(out)
}

fn hex_decode_12(s: &str) -> Result<[u8; 12]> {
    if s.len() != 24 {
        anyhow::bail!("Expected 24 hex chars, got {}", s.len());
    }
    let mut out = [0u8; 12];
    for i in 0..12 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)
            .with_context(|| format!("Invalid hex at position {}", i * 2))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn make_dummy_zip() -> Vec<u8> {
        let mut buf = Vec::new();
        let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));
        let opts = SimpleFileOptions::default();
        zip.start_file("hello.txt", opts).unwrap();
        zip.write_all(b"hello world").unwrap();
        zip.finish().unwrap();
        buf
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let data = b"Hello Vibe!".to_vec();
        let password = b"hunter2";
        let (ciphertext, meta) = encrypt_package(&data, password).unwrap();
        let plaintext = decrypt_package(&ciphertext, password, &meta).unwrap();
        assert_eq!(plaintext, data);
    }

    #[test]
    fn test_wrong_password_fails() {
        let data = b"secret data".to_vec();
        let (ciphertext, meta) = encrypt_package(&data, b"correct").unwrap();
        let result = decrypt_package(&ciphertext, b"wrong", &meta);
        assert!(result.is_err());
    }

    #[test]
    fn test_encrypted_zip_has_two_entries() {
        let dir = tempdir().unwrap();
        let dest = dir.path().join("out.vibeapp");
        let (ciphertext, meta) = encrypt_package(b"payload", b"pw").unwrap();
        write_encrypted_vibeapp(&ciphertext, &meta, &dest).unwrap();

        let data = fs::read(&dest).unwrap();
        let cursor = std::io::Cursor::new(&data);
        let archive = zip::ZipArchive::new(cursor).unwrap();
        assert_eq!(archive.len(), 2);
    }

    #[test]
    fn test_metadata_json_fields() {
        let (_, meta) = encrypt_package(b"test", b"pw").unwrap();
        assert_eq!(meta.version, 1);
        assert_eq!(meta.cipher, "aes-256-gcm");
        assert_eq!(meta.kdf, "argon2id");
        assert_eq!(meta.kdf_params.m_cost, 65536);
        assert_eq!(meta.kdf_params.t_cost, 3);
        assert_eq!(meta.kdf_params.p_cost, 4);
        assert_eq!(meta.kdf_params.salt.len(), 64);
        assert_eq!(meta.nonce.len(), 24);
    }

    #[test]
    fn test_each_encryption_unique() {
        let (ct1, _) = encrypt_package(b"same", b"pw").unwrap();
        let (ct2, _) = encrypt_package(b"same", b"pw").unwrap();
        assert_ne!(ct1, ct2, "Encryptions must differ due to random salt/nonce");
    }

    #[test]
    fn test_is_encrypted_detection() {
        let dir = tempdir().unwrap();
        let enc_path = dir.path().join("enc.vibeapp");
        let plain_path = dir.path().join("plain.vibeapp");

        let (ct, meta) = encrypt_package(b"data", b"pw").unwrap();
        write_encrypted_vibeapp(&ct, &meta, &enc_path).unwrap();
        fs::write(&plain_path, make_dummy_zip()).unwrap();

        assert!(is_encrypted_package(&enc_path));
        assert!(!is_encrypted_package(&plain_path));
    }

    #[test]
    fn test_unencrypted_package_no_password_needed() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("plain.vibeapp");
        let original = make_dummy_zip();
        fs::write(&path, &original).unwrap();

        let bytes = open_package(&path, None, None).unwrap();
        assert_eq!(bytes, original);
    }

    #[test]
    fn open_package_encrypted_with_password() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("enc.vibeapp");
        let original = make_dummy_zip();
        let (ct, meta) = encrypt_package(&original, b"secret").unwrap();
        write_encrypted_vibeapp(&ct, &meta, &path).unwrap();

        let result = open_package(&path, Some("secret"), None).unwrap();
        assert_eq!(result, original);
    }

    #[test]
    fn open_package_nonexistent_err() {
        let result = open_package(std::path::Path::new("/no/such/file.vibeapp"), None, None);
        assert!(result.is_err());
    }

    #[test]
    fn save_package_no_password_writes_raw() {
        let dir = tempdir().unwrap();
        let dest = dir.path().join("out.vibeapp");
        let original = make_dummy_zip();
        save_package(&original, &dest, None, None).unwrap();
        let written = fs::read(&dest).unwrap();
        assert_eq!(written, original);
    }

    #[test]
    fn save_package_with_password_is_encrypted() {
        let dir = tempdir().unwrap();
        let dest = dir.path().join("out.vibeapp");
        let original = make_dummy_zip();
        save_package(&original, &dest, Some("pw"), None).unwrap();
        assert!(is_encrypted_package(&dest));
    }

    #[test]
    fn resolve_password_direct() {
        let result = resolve_password(Some("mypass"), None, "").unwrap();
        assert_eq!(result.as_str(), "mypass");
    }

    #[test]
    fn resolve_password_from_file() {
        let dir = tempdir().unwrap();
        let pw_file = dir.path().join("pw.txt");
        fs::write(&pw_file, "mypass\n").unwrap();
        let result = resolve_password(None, Some(&pw_file), "").unwrap();
        assert_eq!(result.as_str(), "mypass");
    }

    #[test]
    fn resolve_password_file_not_found_err() {
        let result = resolve_password(None, Some(std::path::Path::new("/no/such/pw.txt")), "");
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(
            msg.contains("password file") || msg.contains("Failed"),
            "got: {msg}"
        );
    }

    #[test]
    fn is_encrypted_nonexistent_file() {
        assert!(!is_encrypted_package(std::path::Path::new(
            "/no/such/file.vibeapp"
        )));
    }

    #[test]
    fn is_encrypted_invalid_zip_bytes() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("garbage.vibeapp");
        fs::write(&path, b"this is not a zip file at all").unwrap();
        assert!(!is_encrypted_package(&path));
    }

    #[test]
    fn read_encrypted_missing_encryption_json_err() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("plain.vibeapp");
        fs::write(&path, make_dummy_zip()).unwrap();
        let result = read_encrypted_vibeapp(&path);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("_vibe_encryption.json"), "got: {msg}");
    }

    #[test]
    fn read_encrypted_missing_payload_err() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("partial.vibeapp");
        // ZIP with only _vibe_encryption.json but no payload
        let json = r#"{"version":1,"cipher":"aes-256-gcm","kdf":"argon2id","kdf_params":{"m_cost":65536,"t_cost":3,"p_cost":4,"salt":"0000000000000000000000000000000000000000000000000000000000000000"},"nonce":"000000000000000000000000"}"#;
        let zip_bytes =
            crate::test_helpers::make_zip(&[("_vibe_encryption.json", json.as_bytes())]);
        fs::write(&path, zip_bytes).unwrap();
        let result = read_encrypted_vibeapp(&path);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("_vibe_encrypted_payload"), "got: {msg}");
    }

    #[test]
    fn salt_bytes_wrong_hex_length_err() {
        let meta = EncryptionMetadata {
            version: 1,
            cipher: "aes-256-gcm".to_string(),
            kdf: "argon2id".to_string(),
            kdf_params: KdfParams {
                m_cost: 65536,
                t_cost: 3,
                p_cost: 4,
                salt: "short".to_string(),
            },
            nonce: "000000000000000000000000".to_string(),
        };
        let result = meta.salt_bytes();
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("64") || msg.contains("hex"), "got: {msg}");
    }

    #[test]
    fn nonce_bytes_wrong_hex_length_err() {
        let meta = EncryptionMetadata {
            version: 1,
            cipher: "aes-256-gcm".to_string(),
            kdf: "argon2id".to_string(),
            kdf_params: KdfParams {
                m_cost: 65536,
                t_cost: 3,
                p_cost: 4,
                salt: "0000000000000000000000000000000000000000000000000000000000000000"
                    .to_string(),
            },
            nonce: "short".to_string(),
        };
        let result = meta.nonce_bytes();
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("24") || msg.contains("hex"), "got: {msg}");
    }

    #[test]
    fn derive_key_invalid_params_err() {
        let meta = EncryptionMetadata {
            version: 1,
            cipher: "aes-256-gcm".to_string(),
            kdf: "argon2id".to_string(),
            kdf_params: KdfParams {
                m_cost: 0, // invalid
                t_cost: 3,
                p_cost: 4,
                salt: "0000000000000000000000000000000000000000000000000000000000000000"
                    .to_string(),
            },
            nonce: "000000000000000000000000".to_string(),
        };
        let result = derive_key(b"password", &meta);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(
            msg.contains("Argon2") || msg.contains("Invalid"),
            "got: {msg}"
        );
    }
}
