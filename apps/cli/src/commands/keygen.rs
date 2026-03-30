use std::fs;
use std::io::Write as _;

use anyhow::{Context, Result};
use colored::Colorize;

use vibe_signing::{generate_keypair, signing_key_to_bytes, verifying_key_to_bytes};

pub fn run(output: &str) -> Result<()> {
    let (signing_key, verifying_key) = generate_keypair();

    let sk_bytes = signing_key_to_bytes(&signing_key);
    let vk_bytes = verifying_key_to_bytes(&verifying_key);

    let key_path = format!("{}.key", output);
    let pub_path = format!("{}.pub", output);

    // Use create_new(true) (O_CREAT|O_EXCL) for atomic file creation — this eliminates the
    // TOCTOU race that exists when doing exists() + write() as two separate operations.
    {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&key_path)
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::AlreadyExists {
                    anyhow::anyhow!("Key file '{}' already exists", key_path)
                } else {
                    anyhow::anyhow!("Failed to create '{}': {}", key_path, e)
                }
            })?;
        f.write_all(&sk_bytes)
            .with_context(|| format!("Failed to write signing key to '{}'", key_path))?;
    }
    // Restrict private key to owner-read-only before anyone else can read it
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("Failed to set permissions on '{}'", key_path))?;
    }
    {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&pub_path)
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::AlreadyExists {
                    anyhow::anyhow!("Public key file '{}' already exists", pub_path)
                } else {
                    anyhow::anyhow!("Failed to create '{}': {}", pub_path, e)
                }
            })?;
        f.write_all(&vk_bytes)
            .with_context(|| format!("Failed to write verifying key to '{}'", pub_path))?;
    }

    // Print public key hex to stdout
    let pub_hex: String = vk_bytes.iter().map(|b| format!("{:02x}", b)).collect();

    println!("{} Keypair generated!", "✓".green().bold());
    println!("  {} {}", "Signing key:".dimmed(), key_path);
    println!("  {} {}", "Public key:".dimmed(), pub_path);
    println!("  {} {}", "Public key hex:".dimmed(), pub_hex.cyan());

    Ok(())
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;
    use vibe_signing::{
        sign_package, verify_package, verifying_key_from_bytes, VerificationResult,
    };

    #[test]
    fn creates_key_and_pub_files() {
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        super::run(&prefix).unwrap();
        assert!(std::path::Path::new(&format!("{prefix}.key")).exists());
        assert!(std::path::Path::new(&format!("{prefix}.pub")).exists());
    }

    #[test]
    fn key_file_is_32_bytes() {
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        super::run(&prefix).unwrap();
        let bytes = std::fs::read(format!("{prefix}.key")).unwrap();
        assert_eq!(bytes.len(), 32);
    }

    #[test]
    fn pub_file_is_32_bytes() {
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        super::run(&prefix).unwrap();
        let bytes = std::fs::read(format!("{prefix}.pub")).unwrap();
        assert_eq!(bytes.len(), 32);
    }

    #[cfg(unix)]
    #[test]
    fn key_permissions_0o600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        super::run(&prefix).unwrap();
        let meta = std::fs::metadata(format!("{prefix}.key")).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "key file mode should be 0o600, got 0o{mode:o}");
    }

    #[test]
    fn fails_if_key_exists() {
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        std::fs::write(format!("{prefix}.key"), b"existing").unwrap();
        let result = super::run(&prefix);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("already exists"), "got: {msg}");
    }

    #[test]
    fn fails_if_pub_exists() {
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        std::fs::write(format!("{prefix}.pub"), b"existing").unwrap();
        let result = super::run(&prefix);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("already exists"), "got: {msg}");
    }

    #[test]
    fn keypair_is_functional() {
        use std::collections::BTreeMap;
        let dir = tempdir().unwrap();
        let prefix = dir.path().join("signing").to_str().unwrap().to_string();
        super::run(&prefix).unwrap();
        let key_bytes: [u8; 32] = std::fs::read(format!("{prefix}.key"))
            .unwrap()
            .try_into()
            .unwrap();
        let pub_bytes: [u8; 32] = std::fs::read(format!("{prefix}.pub"))
            .unwrap()
            .try_into()
            .unwrap();
        let signing_key = vibe_signing::signing_key_from_bytes(&key_bytes).unwrap();
        let verifying_key = verifying_key_from_bytes(&pub_bytes).unwrap();
        let digests: BTreeMap<String, [u8; 32]> = BTreeMap::new();
        let hash = vibe_signing::compute_package_hash(&digests);
        let sig = sign_package(&hash, &signing_key);
        assert!(matches!(
            verify_package(&hash, &sig, &verifying_key),
            VerificationResult::Valid
        ));
    }

    #[test]
    fn produces_unique_keys() {
        let dir1 = tempdir().unwrap();
        let dir2 = tempdir().unwrap();
        let prefix1 = dir1.path().join("s").to_str().unwrap().to_string();
        let prefix2 = dir2.path().join("s").to_str().unwrap().to_string();
        super::run(&prefix1).unwrap();
        super::run(&prefix2).unwrap();
        let k1 = std::fs::read(format!("{prefix1}.key")).unwrap();
        let k2 = std::fs::read(format!("{prefix2}.key")).unwrap();
        assert_ne!(k1, k2, "Two generated keys should differ");
    }
}
