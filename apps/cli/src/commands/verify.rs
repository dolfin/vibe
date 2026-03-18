use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use ed25519_dalek::Signature;
use sha2::{Digest, Sha256};
use zip::read::ZipArchive;

use vibe_signing::{
    compute_package_hash, verify_package, verifying_key_from_bytes, VerificationResult,
};

pub fn run(
    package_path: &Path,
    key_path: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<()> {
    println!("Verifying {}...", package_path.display().to_string().cyan());

    // Read public key (32 bytes raw)
    let key_bytes = std::fs::read(key_path)
        .with_context(|| format!("Failed to read key file '{}'", key_path.display()))?;
    if key_bytes.len() != 32 {
        anyhow::bail!(
            "Invalid key file: expected 32 bytes, got {}",
            key_bytes.len()
        );
    }
    let key_array: [u8; 32] = key_bytes.try_into().unwrap();
    let verifying_key =
        verifying_key_from_bytes(&key_array).context("Failed to parse verifying key")?;

    // Open package (decrypt in memory if encrypted)
    let zip_data = crate::crypto::open_package(package_path, password, password_file)?;

    let cursor = std::io::Cursor::new(&zip_data);
    let mut archive = ZipArchive::new(cursor).context("Failed to open package as ZIP archive")?;

    // Extract _vibe_package_manifest.json
    let pkg_manifest_json = {
        let mut file = archive
            .by_name("_vibe_package_manifest.json")
            .context("Package missing _vibe_package_manifest.json")?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        contents
    };

    // Extract _vibe_signature.sig
    let sig_bytes = {
        let mut file = archive
            .by_name("_vibe_signature.sig")
            .context("Package missing _vibe_signature.sig (not signed?)")?;
        let mut contents = Vec::new();
        file.read_to_end(&mut contents)?;
        contents
    };

    if sig_bytes.len() != 64 {
        anyhow::bail!(
            "Invalid signature: expected 64 bytes, got {}",
            sig_bytes.len()
        );
    }
    let sig_array: [u8; 64] = sig_bytes.try_into().unwrap();
    let signature = Signature::from_bytes(&sig_array);

    // Parse file digests from package manifest
    let pkg_manifest: serde_json::Value =
        serde_json::from_str(&pkg_manifest_json).context("Failed to parse package manifest")?;
    let files = pkg_manifest["files"]
        .as_object()
        .context("Package manifest missing 'files' field")?;

    let mut file_digests: BTreeMap<String, [u8; 32]> = BTreeMap::new();
    for (path, hash_val) in files {
        let hash_hex = hash_val.as_str().context("File hash is not a string")?;
        let hash_bytes = hex_decode(hash_hex).context("Invalid hex in file digest")?;
        file_digests.insert(path.clone(), hash_bytes);
    }

    // Verify signature over package hash
    let package_hash = compute_package_hash(&file_digests);
    let result = verify_package(&package_hash, &signature, &verifying_key);

    match result {
        VerificationResult::Valid => {
            println!("{} Signature is valid!", "✓".green().bold());
        }
        VerificationResult::Invalid(failure) => {
            println!(
                "{} Signature verification failed: {:?}",
                "✗".red().bold(),
                failure
            );
            anyhow::bail!("Signature verification failed");
        }
    }

    // Verify each file's hash matches the manifest
    println!("Verifying file integrity...");
    let mut integrity_ok = true;

    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();

        // Skip metadata files
        if name == "_vibe_package_manifest.json" || name == "_vibe_signature.sig" {
            continue;
        }

        let mut contents = Vec::new();
        file.read_to_end(&mut contents)?;

        if let Some(expected_hash) = file_digests.get(&name) {
            let mut hasher = Sha256::new();
            hasher.update(&contents);
            let actual_hash: [u8; 32] = hasher.finalize().into();

            if &actual_hash != expected_hash {
                println!("  {} {} hash mismatch!", "✗".red(), name);
                integrity_ok = false;
            } else {
                println!("  {} {}", "✓".green(), name);
            }
        } else {
            println!(
                "  {} {} not in manifest (unexpected file)",
                "?".yellow(),
                name
            );
        }
    }

    if !integrity_ok {
        anyhow::bail!("File integrity check failed");
    }

    println!(
        "\n{} Package verification complete - all checks passed!",
        "✓".green().bold()
    );

    Ok(())
}

fn hex_decode(hex: &str) -> Result<[u8; 32]> {
    if hex.len() != 64 {
        anyhow::bail!("Expected 64 hex characters, got {}", hex.len());
    }
    let mut bytes = [0u8; 32];
    for i in 0..32 {
        bytes[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
            .with_context(|| format!("Invalid hex at position {}", i * 2))?;
    }
    Ok(bytes)
}
