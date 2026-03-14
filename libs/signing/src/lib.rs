use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

pub use ed25519_dalek::{Signature, SigningKey, VerifyingKey};
use ed25519_dalek::{Signer, Verifier};
use rand::rngs::OsRng;
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SigningError {
    #[error("invalid key bytes: {0}")]
    InvalidKey(String),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, SigningError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerificationResult {
    Valid,
    Invalid(VerificationFailure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerificationFailure {
    SignatureMismatch,
    InvalidKey,
    InvalidSignature,
    HashMismatch {
        expected: [u8; 32],
        actual: [u8; 32],
    },
}

/// Generate a new Ed25519 keypair.
pub fn generate_keypair() -> (SigningKey, VerifyingKey) {
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();
    (signing_key, verifying_key)
}

/// Serialize a signing key to its 32-byte seed representation.
pub fn signing_key_to_bytes(key: &SigningKey) -> [u8; 32] {
    key.to_bytes()
}

/// Deserialize a signing key from 32 bytes.
pub fn signing_key_from_bytes(bytes: &[u8; 32]) -> Result<SigningKey> {
    Ok(SigningKey::from_bytes(bytes))
}

/// Serialize a verifying key to 32 bytes.
pub fn verifying_key_to_bytes(key: &VerifyingKey) -> [u8; 32] {
    key.to_bytes()
}

/// Deserialize a verifying key from 32 bytes.
pub fn verifying_key_from_bytes(bytes: &[u8; 32]) -> Result<VerifyingKey> {
    VerifyingKey::from_bytes(bytes).map_err(|e| SigningError::InvalidKey(e.to_string()))
}

/// SHA-256 hash of raw bytes.
pub fn hash_bytes(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

/// SHA-256 hash of a file's contents.
pub fn hash_file(path: &Path) -> Result<[u8; 32]> {
    let data = fs::read(path)?;
    Ok(hash_bytes(&data))
}

/// Compute a deterministic package hash from individual file digests.
///
/// The digests are sorted by key (guaranteed by `BTreeMap`), serialized to
/// JSON, and then SHA-256 hashed.
pub fn compute_package_hash(file_digests: &BTreeMap<String, [u8; 32]>) -> [u8; 32] {
    let serialized = serde_json::to_vec(file_digests)
        .expect("BTreeMap<String, [u8; 32]> serialization cannot fail");
    hash_bytes(&serialized)
}

/// Sign arbitrary data with the given signing key.
pub fn sign(data: &[u8], key: &SigningKey) -> Signature {
    key.sign(data)
}

/// Sign a package hash.
pub fn sign_package(package_hash: &[u8; 32], key: &SigningKey) -> Signature {
    sign(package_hash.as_slice(), key)
}

/// Verify a signature over arbitrary data.
pub fn verify(data: &[u8], signature: &Signature, key: &VerifyingKey) -> VerificationResult {
    match key.verify(data, signature) {
        Ok(()) => VerificationResult::Valid,
        Err(_) => VerificationResult::Invalid(VerificationFailure::SignatureMismatch),
    }
}

/// Verify a signature over a package hash.
pub fn verify_package(
    package_hash: &[u8; 32],
    signature: &Signature,
    key: &VerifyingKey,
) -> VerificationResult {
    verify(package_hash.as_slice(), signature, key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn sign_and_verify_round_trip() {
        let (sk, vk) = generate_keypair();
        let data = b"hello vibe";
        let sig = sign(data, &sk);
        assert_eq!(verify(data, &sig, &vk), VerificationResult::Valid);
    }

    #[test]
    fn tampered_data_fails_verification() {
        let (sk, vk) = generate_keypair();
        let sig = sign(b"original", &sk);
        assert_eq!(
            verify(b"tampered", &sig, &vk),
            VerificationResult::Invalid(VerificationFailure::SignatureMismatch),
        );
    }

    #[test]
    fn wrong_key_fails_verification() {
        let (sk, _vk) = generate_keypair();
        let (_sk2, vk2) = generate_keypair();
        let data = b"test data";
        let sig = sign(data, &sk);
        assert_eq!(
            verify(data, &sig, &vk2),
            VerificationResult::Invalid(VerificationFailure::SignatureMismatch),
        );
    }

    #[test]
    fn package_hash_is_deterministic() {
        let mut digests = BTreeMap::new();
        digests.insert("a.wasm".to_string(), [1u8; 32]);
        digests.insert("b.wasm".to_string(), [2u8; 32]);

        let h1 = compute_package_hash(&digests);
        let h2 = compute_package_hash(&digests);
        assert_eq!(h1, h2);

        let mut digests_rev = BTreeMap::new();
        digests_rev.insert("b.wasm".to_string(), [2u8; 32]);
        digests_rev.insert("a.wasm".to_string(), [1u8; 32]);
        assert_eq!(h1, compute_package_hash(&digests_rev));
    }

    #[test]
    fn file_hashing_works() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.bin");
        {
            let mut f = fs::File::create(&file_path).unwrap();
            f.write_all(b"file content").unwrap();
        }
        let hash = hash_file(&file_path).unwrap();
        assert_eq!(hash, hash_bytes(b"file content"));
    }

    #[test]
    fn signing_key_byte_round_trip() {
        let (sk, _vk) = generate_keypair();
        let bytes = signing_key_to_bytes(&sk);
        let sk2 = signing_key_from_bytes(&bytes).unwrap();
        assert_eq!(sk.to_bytes(), sk2.to_bytes());
    }

    #[test]
    fn verifying_key_byte_round_trip() {
        let (_sk, vk) = generate_keypair();
        let bytes = verifying_key_to_bytes(&vk);
        let vk2 = verifying_key_from_bytes(&bytes).unwrap();
        assert_eq!(vk.to_bytes(), vk2.to_bytes());
    }

    /// Cross-language test vector: same inputs must produce the same package hash
    /// in both Rust and Swift. If this test changes, update the Swift test too.
    #[test]
    fn cross_language_package_hash_vector() {
        let mut digests = BTreeMap::new();
        // Deterministic test data: "hello" hashed and "world" hashed
        digests.insert(
            "file_a.txt".to_string(),
            [
                0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e, 0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9,
                0xe2, 0x9e, 0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e, 0x73, 0x04, 0x33, 0x62,
                0x93, 0x8b, 0x98, 0x24,
            ],
        );
        digests.insert(
            "file_b.txt".to_string(),
            [
                0x48, 0x6e, 0xa4, 0x62, 0x24, 0xd1, 0xbb, 0x4f, 0xb6, 0x80, 0xf3, 0x4f, 0x7c, 0x9a,
                0xd9, 0x6a, 0x8f, 0x24, 0xec, 0x88, 0xbe, 0x73, 0xea, 0x8e, 0x5a, 0x6c, 0x65, 0x26,
                0x0e, 0x9c, 0xb8, 0xa7,
            ],
        );

        let hash = compute_package_hash(&digests);
        let hash_hex: String = hash.iter().map(|b| format!("{:02x}", b)).collect();

        // This expected value must match the Swift test in VibeHostTests.swift
        assert_eq!(
            hash_hex,
            "d81e92910f937cc88964af9f60f14581ec28734e252dadb66e37bed5f67d6fa4",
        );

        // Also verify the JSON serialization format for documentation
        let json = serde_json::to_vec(&digests).unwrap();
        let json_str = String::from_utf8(json).unwrap();
        // Serde serializes [u8; 32] as a JSON integer array
        assert!(json_str.starts_with("{\"file_a.txt\":["));
        assert!(json_str.contains(",\"file_b.txt\":["));
    }

    #[test]
    fn package_sign_and_verify() {
        let (sk, vk) = generate_keypair();
        let mut digests = BTreeMap::new();
        digests.insert("main.wasm".to_string(), hash_bytes(b"wasm bytes"));
        let pkg_hash = compute_package_hash(&digests);
        let sig = sign_package(&pkg_hash, &sk);
        assert_eq!(
            verify_package(&pkg_hash, &sig, &vk),
            VerificationResult::Valid,
        );
    }
}
