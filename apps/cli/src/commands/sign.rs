use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use ed25519_dalek::Signature;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;
use zip::read::ZipArchive;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use vibe_signing::{compute_package_hash, sign_package, signing_key_from_bytes};

pub fn run(
    package_path: &Path,
    key_path: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
    embed_key: bool,
) -> Result<()> {
    println!("Signing {}...", package_path.display().to_string().cyan());

    // Read private key (32 bytes raw) into a Zeroizing buffer so it is
    // wiped from memory as soon as we're done with it.
    let key_bytes = Zeroizing::new(
        fs::read(key_path)
            .with_context(|| format!("Failed to read key file '{}'", key_path.display()))?,
    );
    if key_bytes.len() != 32 {
        anyhow::bail!(
            "Invalid key file: expected 32 bytes, got {}",
            key_bytes.len()
        );
    }
    let key_array: Zeroizing<[u8; 32]> = Zeroizing::new(key_bytes.as_slice().try_into().unwrap());
    let signing_key = signing_key_from_bytes(&key_array).context("Failed to parse signing key")?;

    // Resolve password once upfront (avoids double-prompting for interactive mode).
    // Stored in Zeroizing<String> so the plaintext is wiped when dropped.
    let is_encrypted = crate::crypto::is_encrypted_package(package_path);
    let resolved_pw: Option<Zeroizing<String>> = if is_encrypted {
        Some(crate::crypto::resolve_password(
            password,
            password_file,
            "Password: ",
        )?)
    } else {
        None
    };
    let pw_ref = resolved_pw.as_deref().map(|s| s.as_str());

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

    // Collect all ZIP entries (excluding any existing signature)
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

    // Embed the signer's public key when --embed-key is set.
    // Adds _vibe_publisher.pub, patches _vibe_app_manifest.json to reference it,
    // and updates _vibe_package_manifest.json and file_digests accordingly.
    if embed_key {
        let verifying_key_bytes = signing_key.verifying_key().to_bytes();

        // Hash the public key and register it as a package file
        let pub_key_hash: [u8; 32] = Sha256::digest(verifying_key_bytes).into();
        file_digests.insert("_vibe_publisher.pub".to_string(), pub_key_hash);
        all_entries.insert(
            "_vibe_publisher.pub".to_string(),
            verifying_key_bytes.to_vec(),
        );

        // Patch _vibe_app_manifest.json to reference the embedded key
        if let Some(app_manifest_bytes) = all_entries.get("_vibe_app_manifest.json").cloned() {
            let app_manifest_str = String::from_utf8(app_manifest_bytes)
                .context("_vibe_app_manifest.json is not valid UTF-8")?;
            let mut app_manifest_val: serde_json::Value =
                serde_json::from_str(&app_manifest_str)
                    .context("Failed to parse _vibe_app_manifest.json")?;

            app_manifest_val["publisher"]["signing"]["publicKeyFile"] =
                serde_json::Value::String("_vibe_publisher.pub".to_string());

            let new_app_manifest = serde_json::to_string(&app_manifest_val)
                .context("Failed to serialize updated _vibe_app_manifest.json")?;
            let new_app_manifest_bytes = new_app_manifest.into_bytes();

            let app_manifest_hash: [u8; 32] = Sha256::digest(&new_app_manifest_bytes).into();
            file_digests.insert("_vibe_app_manifest.json".to_string(), app_manifest_hash);
            all_entries.insert(
                "_vibe_app_manifest.json".to_string(),
                new_app_manifest_bytes,
            );
        }

        // Re-serialize _vibe_package_manifest.json with the updated file_digests
        let mut pkg_manifest_val: serde_json::Value = serde_json::from_str(&pkg_manifest_json)
            .context("Failed to re-parse package manifest")?;
        let files_obj: serde_json::Map<String, serde_json::Value> = file_digests
            .iter()
            .map(|(k, v)| {
                let hex = v.iter().map(|b| format!("{:02x}", b)).collect::<String>();
                (k.clone(), serde_json::Value::String(hex))
            })
            .collect();
        pkg_manifest_val["files"] = serde_json::Value::Object(files_obj);
        let new_pkg_manifest = serde_json::to_string(&pkg_manifest_val)
            .context("Failed to serialize updated package manifest")?;
        all_entries.insert(
            "_vibe_package_manifest.json".to_string(),
            new_pkg_manifest.into_bytes(),
        );
    }

    // Compute package hash and sign
    let package_hash = compute_package_hash(&file_digests);
    let signature: Signature = sign_package(&package_hash, &signing_key);
    let sig_bytes = signature.to_bytes();

    all_entries.insert("_vibe_signature.sig".to_string(), sig_bytes.to_vec());

    // Re-create the ZIP with all entries
    let mut new_zip_data = Vec::new();
    {
        let mut zip_writer = ZipWriter::new(std::io::Cursor::new(&mut new_zip_data));
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        for (name, contents) in &all_entries {
            zip_writer.start_file(name, options)?;
            zip_writer.write_all(contents)?;
        }

        zip_writer.finish()?;
    }

    // Write back: re-encrypt if original was encrypted, otherwise write plain.
    // pw is Zeroizing<String>; pass as bytes without copying into a plain String.
    if let Some(pw) = resolved_pw {
        let (ciphertext, enc_meta) = crate::crypto::encrypt_package(&new_zip_data, pw.as_bytes())?;
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

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tempfile::tempdir;

    use crate::test_helpers::{
        assert_zip_contains, build_encrypted_package, build_package, read_zip_entry,
        write_minimal_project,
    };

    fn keygen(dir: &std::path::Path) -> (std::path::PathBuf, std::path::PathBuf) {
        let prefix = dir.join("_signing").to_str().unwrap().to_string();
        crate::commands::keygen::run(&prefix).unwrap();
        (
            std::path::PathBuf::from(format!("{prefix}.key")),
            std::path::PathBuf::from(format!("{prefix}.pub")),
        )
    }

    #[test]
    fn adds_signature_entry() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let (key_path, _) = keygen(dir.path());
        super::run(&output, &key_path, None, None, false).unwrap();
        assert_zip_contains(&output, "_vibe_signature.sig");
    }

    #[test]
    fn signature_is_64_bytes() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let (key_path, _) = keygen(dir.path());
        super::run(&output, &key_path, None, None, false).unwrap();
        let sig = read_zip_entry(&output, "_vibe_signature.sig");
        assert_eq!(sig.len(), 64);
    }

    #[test]
    fn re_sign_has_single_signature() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let (key_path, _) = keygen(dir.path());
        // Sign twice
        super::run(&output, &key_path, None, None, false).unwrap();
        super::run(&output, &key_path, None, None, false).unwrap();
        // Count signature entries
        let data = std::fs::read(&output).unwrap();
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data)).unwrap();
        let count = (0..archive.len())
            .filter(|&i| archive.by_index(i).unwrap().name() == "_vibe_signature.sig")
            .count();
        assert_eq!(count, 1, "should have exactly one signature entry");
    }

    #[test]
    fn different_key_produces_different_sig() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");

        let out1 = dir.path().join("out1.vibeapp");
        let out2 = dir.path().join("out2.vibeapp");
        build_package(&manifest, &out1);
        std::fs::copy(&out1, &out2).unwrap();

        let prefix1 = dir.path().join("k1").to_str().unwrap().to_string();
        let prefix2 = dir.path().join("k2").to_str().unwrap().to_string();
        crate::commands::keygen::run(&prefix1).unwrap();
        crate::commands::keygen::run(&prefix2).unwrap();
        let key1 = std::path::PathBuf::from(format!("{prefix1}.key"));
        let key2 = std::path::PathBuf::from(format!("{prefix2}.key"));

        super::run(&out1, &key1, None, None, false).unwrap();
        super::run(&out2, &key2, None, None, false).unwrap();

        let sig1 = read_zip_entry(&out1, "_vibe_signature.sig");
        let sig2 = read_zip_entry(&out2, "_vibe_signature.sig");
        assert_ne!(sig1, sig2);
    }

    #[test]
    fn nonexistent_package_err() {
        let dir = tempdir().unwrap();
        let (key_path, _) = keygen(dir.path());
        assert!(super::run(
            Path::new("/no/such/file.vibeapp"),
            &key_path,
            None,
            None,
            false
        )
        .is_err());
    }

    #[test]
    fn nonexistent_key_err() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        assert!(super::run(&output, Path::new("/no/such/key.key"), None, None, false).is_err());
    }

    #[test]
    fn invalid_key_wrong_size_err() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let bad_key = dir.path().join("bad.key");
        std::fs::write(&bad_key, b"tooshort").unwrap();
        let result = super::run(&output, &bad_key, None, None, false);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(
            msg.contains("expected 32 bytes") || msg.contains("32"),
            "got: {msg}"
        );
    }

    #[test]
    fn encrypted_package_with_password() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_encrypted_package(&manifest, &output, "mypass");
        let (key_path, _) = keygen(dir.path());
        super::run(&output, &key_path, Some("mypass"), None, false).unwrap();
        // Should still be encrypted after signing
        assert!(crate::crypto::is_encrypted_package(&output));
    }

    #[test]
    fn missing_package_manifest_err() {
        let dir = tempdir().unwrap();
        let output = dir.path().join("out.vibeapp");
        // Build ZIP without _vibe_package_manifest.json
        let zip_bytes = crate::test_helpers::make_zip(&[("readme.txt", b"hello")]);
        std::fs::write(&output, &zip_bytes).unwrap();
        let (key_path, _) = keygen(dir.path());
        assert!(super::run(&output, &key_path, None, None, false).is_err());
    }

    #[test]
    fn embed_key_adds_publisher_pub() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let (key_path, pub_path) = keygen(dir.path());
        super::run(&output, &key_path, None, None, true).unwrap();

        // Package should contain the publisher public key
        assert_zip_contains(&output, "_vibe_publisher.pub");

        // The embedded key bytes should match the .pub file
        let embedded = read_zip_entry(&output, "_vibe_publisher.pub");
        let expected = std::fs::read(&pub_path).unwrap();
        assert_eq!(embedded, expected);
    }

    #[test]
    fn embed_key_sets_public_key_file_in_app_manifest() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let (key_path, _) = keygen(dir.path());
        super::run(&output, &key_path, None, None, true).unwrap();

        let app_manifest_bytes = read_zip_entry(&output, "_vibe_app_manifest.json");
        let app_manifest: serde_json::Value = serde_json::from_slice(&app_manifest_bytes).unwrap();
        assert_eq!(
            app_manifest["publisher"]["signing"]["publicKeyFile"],
            serde_json::Value::String("_vibe_publisher.pub".to_string())
        );
    }

    #[test]
    fn embed_key_package_verifies_with_embedded_key() {
        use ed25519_dalek::Signature as DalekSignature;
        use std::io::Read as _;
        use vibe_signing::{
            compute_package_hash, verify_package, VerificationResult, VerifyingKey,
        };
        use zip::ZipArchive;

        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_package(&manifest, &output);
        let (key_path, pub_path) = keygen(dir.path());
        super::run(&output, &key_path, None, None, true).unwrap();

        // Read the package and verify using the embedded public key
        let data = std::fs::read(&output).unwrap();
        let mut archive = ZipArchive::new(std::io::Cursor::new(&data)).unwrap();

        let pkg_manifest_json = {
            let mut f = archive.by_name("_vibe_package_manifest.json").unwrap();
            let mut s = String::new();
            f.read_to_string(&mut s).unwrap();
            s
        };
        let pkg_manifest: serde_json::Value = serde_json::from_str(&pkg_manifest_json).unwrap();
        let files = pkg_manifest["files"].as_object().unwrap();
        let mut file_digests = std::collections::BTreeMap::new();
        for (k, v) in files {
            let hex = v.as_str().unwrap();
            let mut bytes = [0u8; 32];
            for i in 0..32 {
                bytes[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap();
            }
            file_digests.insert(k.clone(), bytes);
        }

        let sig_bytes = read_zip_entry(&output, "_vibe_signature.sig");
        let sig_arr: [u8; 64] = sig_bytes.try_into().unwrap();
        let signature = DalekSignature::from_bytes(&sig_arr);

        let pub_key_bytes = std::fs::read(&pub_path).unwrap();
        let pub_key_arr: [u8; 32] = pub_key_bytes.try_into().unwrap();
        let verifying_key = VerifyingKey::from_bytes(&pub_key_arr).unwrap();

        let package_hash = compute_package_hash(&file_digests);
        assert_eq!(
            verify_package(&package_hash, &signature, &verifying_key),
            VerificationResult::Valid
        );
    }
}
