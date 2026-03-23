use std::io::{Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

/// Strip `_vibe_state/*` entries from a .vibeapp, restoring it to its original signed state.
pub fn run(
    package: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<()> {
    println!(
        "Reverting {}...",
        package.display().to_string().cyan()
    );

    // Resolve password once upfront to avoid double-prompting
    let is_encrypted = crate::crypto::is_encrypted_package(package);
    let resolved_pw: Option<String> = if is_encrypted {
        Some(crate::crypto::resolve_password(
            password,
            password_file,
            "Password: ",
        )?)
    } else {
        None
    };

    let data = crate::crypto::open_package(package, resolved_pw.as_deref(), None)?;

    let reader = std::io::Cursor::new(&data);
    let mut archive =
        zip::ZipArchive::new(reader).context("Failed to open ZIP archive")?;

    // Collect entry names first (borrow checker requires two passes)
    let names: Vec<String> = (0..archive.len())
        .map(|i| archive.by_index(i).map(|e| e.name().to_string()))
        .collect::<std::result::Result<_, _>>()
        .context("Failed to enumerate archive entries")?;

    let mut kept = 0usize;
    let mut removed = 0usize;

    // Build new inner ZIP in memory
    let mut new_zip_bytes = Vec::new();
    {
        let mut zip = ZipWriter::new(std::io::Cursor::new(&mut new_zip_bytes));
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        for name in &names {
            if name.starts_with("_vibe_state/") {
                removed += 1;
                println!("  {} Removing {}", "-".red(), name);
                continue;
            }

            let mut entry = archive.by_name(name).context("Failed to get archive entry")?;
            let mut buf = Vec::new();
            entry
                .read_to_end(&mut buf)
                .with_context(|| format!("Failed to read entry '{}'", name))?;
            zip.start_file(name, options)
                .with_context(|| format!("Failed to write entry '{}'", name))?;
            zip.write_all(&buf)
                .with_context(|| format!("Failed to write data for '{}'", name))?;
            kept += 1;
        }

        zip.finish().context("Failed to finalize ZIP")?;
    }

    // Write atomically via temp file
    let tmp_path = package.with_extension("vibeapp.tmp");

    if let Some(pw) = resolved_pw {
        let (ciphertext, meta) = crate::crypto::encrypt_package(&new_zip_bytes, pw.as_bytes())?;
        crate::crypto::write_encrypted_vibeapp(&ciphertext, &meta, &tmp_path)?;
    } else {
        std::fs::write(&tmp_path, &new_zip_bytes)
            .with_context(|| format!("Failed to write temp file '{}'", tmp_path.display()))?;
    }

    std::fs::rename(&tmp_path, package)
        .with_context(|| format!("Failed to rename '{}' to '{}'", tmp_path.display(), package.display()))?;

    println!("{} Reverted!", "✓".green().bold());
    println!(
        "  {} {} entries kept, {} state entries removed",
        "Summary:".dimmed(),
        kept,
        removed
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;
    use std::path::Path;

    use tempfile::tempdir;
    use zip::write::SimpleFileOptions;
    use zip::ZipWriter;

    use crate::test_helpers::{
        build_encrypted_package, make_zip, write_minimal_project,
    };

    fn make_zip_with_state() -> Vec<u8> {
        crate::test_helpers::make_zip(&[
            ("_vibe_package_manifest.json", b"{\"format_version\":\"1\",\"app_id\":\"com.example.test\",\"app_version\":\"0.1.0\",\"created_at\":\"2024-01-01T00:00:00Z\",\"files\":{}}"),
            ("index.html", b"<html></html>"),
            ("_vibe_state/snap.tar.gz", b"fake tar data"),
        ])
    }

    #[test]
    fn no_state_entries_is_noop() {
        let dir = tempdir().unwrap();
        let output = dir.path().join("out.vibeapp");
        let zip_bytes = make_zip(&[("index.html", b"hello"), ("_vibe_package_manifest.json", b"{}")]);
        std::fs::write(&output, &zip_bytes).unwrap();
        assert!(super::run(&output, None, None).is_ok());
        assert!(output.exists());
    }

    #[test]
    fn removes_state_entries() {
        let dir = tempdir().unwrap();
        let output = dir.path().join("out.vibeapp");
        std::fs::write(&output, make_zip_with_state()).unwrap();
        super::run(&output, None, None).unwrap();
        crate::test_helpers::assert_zip_not_contains(&output, "_vibe_state/snap.tar.gz");
    }

    #[test]
    fn preserves_non_state_entries() {
        let dir = tempdir().unwrap();
        let output = dir.path().join("out.vibeapp");
        std::fs::write(&output, make_zip_with_state()).unwrap();
        super::run(&output, None, None).unwrap();
        crate::test_helpers::assert_zip_contains(&output, "index.html");
        crate::test_helpers::assert_zip_contains(&output, "_vibe_package_manifest.json");
    }

    #[test]
    fn reverted_file_is_valid_zip() {
        let dir = tempdir().unwrap();
        let output = dir.path().join("out.vibeapp");
        std::fs::write(&output, make_zip_with_state()).unwrap();
        super::run(&output, None, None).unwrap();
        let data = std::fs::read(&output).unwrap();
        assert!(zip::ZipArchive::new(std::io::Cursor::new(data)).is_ok());
    }

    #[test]
    fn encrypted_revert_stays_encrypted() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_encrypted_package(&manifest, &output, "pw123");

        // Inject a _vibe_state entry into the encrypted package
        let inner = crate::crypto::open_package(&output, Some("pw123"), None).unwrap();
        let inner_data = std::fs::read(&output).unwrap(); // dummy; we'll rebuild
        let _ = inner_data;

        // Read inner ZIP, add state entry, re-encrypt
        let inner_with_state = {
            let mut archive =
                zip::ZipArchive::new(std::io::Cursor::new(&inner)).unwrap();
            let names: Vec<String> = (0..archive.len())
                .map(|i| archive.by_index(i).unwrap().name().to_string())
                .collect();
            let mut buf = Vec::new();
            let mut writer = ZipWriter::new(std::io::Cursor::new(&mut buf));
            let opts = SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for name in &names {
                let mut entry = archive.by_name(name).unwrap();
                let mut contents = Vec::new();
                std::io::Read::read_to_end(&mut entry, &mut contents).unwrap();
                writer.start_file(name, opts).unwrap();
                writer.write_all(&contents).unwrap();
            }
            writer.start_file("_vibe_state/snap.tar.gz", opts).unwrap();
            writer.write_all(b"fake state").unwrap();
            writer.finish().unwrap();
            buf
        };
        let (ct, meta) = crate::crypto::encrypt_package(&inner_with_state, b"pw123").unwrap();
        crate::crypto::write_encrypted_vibeapp(&ct, &meta, &output).unwrap();

        super::run(&output, Some("pw123"), None).unwrap();
        assert!(crate::crypto::is_encrypted_package(&output));
    }

    #[test]
    fn encrypted_wrong_password_err() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        build_encrypted_package(&manifest, &output, "correct");
        assert!(super::run(&output, Some("wrong"), None).is_err());
    }

    #[test]
    fn nonexistent_package_err() {
        assert!(super::run(Path::new("/no/such.vibeapp"), None, None).is_err());
    }
}
