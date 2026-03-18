use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use ed25519_dalek::Signature;
use zip::read::ZipArchive;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use vibe_signing::{compute_package_hash, sign_package, signing_key_from_bytes};

pub fn run(
    package_path: &Path,
    key_path: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<()> {
    println!("Signing {}...", package_path.display().to_string().cyan());

    // Read private key (32 bytes raw)
    let key_bytes = fs::read(key_path)
        .with_context(|| format!("Failed to read key file '{}'", key_path.display()))?;
    if key_bytes.len() != 32 {
        anyhow::bail!(
            "Invalid key file: expected 32 bytes, got {}",
            key_bytes.len()
        );
    }
    let key_array: [u8; 32] = key_bytes.try_into().unwrap();
    let signing_key = signing_key_from_bytes(&key_array).context("Failed to parse signing key")?;

    // Resolve password once upfront (avoids double-prompting for interactive mode)
    let is_encrypted = crate::crypto::is_encrypted_package(package_path);
    let resolved_pw: Option<String> = if is_encrypted {
        Some(crate::crypto::resolve_password(
            password,
            password_file,
            "Password: ",
        )?)
    } else {
        None
    };
    let pw_ref = resolved_pw.as_deref();

    // Open package (decrypt if encrypted)
    let zip_data = crate::crypto::open_package(package_path, pw_ref, None)?;

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

    // Compute package hash and sign
    let package_hash = compute_package_hash(&file_digests);
    let signature: Signature = sign_package(&package_hash, &signing_key);
    let sig_bytes = signature.to_bytes();

    // Re-create the inner zip with the signature included
    let mut new_zip_data = Vec::new();
    {
        let mut zip_writer = ZipWriter::new(std::io::Cursor::new(&mut new_zip_data));
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        let mut all_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();

        for i in 0..archive.len() {
            let mut file = archive.by_index(i)?;
            let name = file.name().to_string();
            if name == "_vibe_signature.sig" {
                continue;
            }
            let mut contents = Vec::new();
            file.read_to_end(&mut contents)?;
            all_entries.insert(name, contents);
        }

        all_entries.insert("_vibe_signature.sig".to_string(), sig_bytes.to_vec());

        for (name, contents) in &all_entries {
            zip_writer.start_file(name, options)?;
            zip_writer.write_all(contents)?;
        }

        zip_writer.finish()?;
    }

    // Write back: re-encrypt if original was encrypted, otherwise write plain
    if let Some(pw) = resolved_pw {
        let (ciphertext, enc_meta) =
            crate::crypto::encrypt_package(&new_zip_data, pw.as_bytes())?;
        crate::crypto::write_encrypted_vibeapp(&ciphertext, &enc_meta, package_path)?;
    } else {
        fs::write(package_path, &new_zip_data).with_context(|| {
            format!(
                "Failed to write signed package to '{}'",
                package_path.display()
            )
        })?;
    }

    println!("{} Package signed successfully!", "✓".green().bold());
    println!(
        "  {} Signature embedded in {}",
        "→".dimmed(),
        package_path.display().to_string().cyan()
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
