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
