use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use colored::Colorize;
use serde::Serialize;
use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

use vibe_manifest::parse::{parse_manifest_file, serialize_manifest_json};
use vibe_manifest::validate::validate_manifest;

#[derive(Serialize)]
struct PackageManifest {
    format_version: String,
    app_id: String,
    app_version: String,
    created_at: String,
    files: BTreeMap<String, String>,
}

pub fn run(
    manifest_path: &Path,
    output: Option<&Path>,
    seed_data: Option<&Path>,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<()> {
    println!(
        "Packaging from {}...",
        manifest_path.display().to_string().cyan()
    );

    // Parse and validate manifest
    let manifest = parse_manifest_file(manifest_path)
        .with_context(|| format!("Failed to parse manifest at '{}'", manifest_path.display()))?;

    match validate_manifest(&manifest) {
        Ok(()) => {}
        Err(errors) => {
            for err in &errors {
                eprintln!("  {} {}", "•".red(), err);
            }
            anyhow::bail!("Manifest validation failed with {} error(s)", errors.len());
        }
    }

    let app_id = manifest
        .id
        .as_deref()
        .context("Manifest missing 'id' field")?;
    let app_version = manifest
        .version
        .as_deref()
        .context("Manifest missing 'version' field")?;

    // Determine project directory (parent of manifest file)
    let project_dir = manifest_path
        .parent()
        .unwrap_or(Path::new("."))
        .canonicalize()
        .context("Failed to resolve project directory")?;

    // Collect all files in the project directory
    let mut file_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    collect_files(&project_dir, &project_dir, &mut file_entries)?;

    // Serialize app manifest to JSON for Swift host consumption
    let app_manifest_json =
        serialize_manifest_json(&manifest).context("Failed to serialize app manifest to JSON")?;
    file_entries.insert(
        "_vibe_app_manifest.json".to_string(),
        app_manifest_json.into_bytes(),
    );

    // Embed seed data as _vibe_initial_state/<name>.tar.gz if provided.
    // These entries are included in the signed manifest so they cannot be tampered with.
    if let Some(seed_dir) = seed_data {
        let seed_dir = seed_dir
            .canonicalize()
            .with_context(|| format!("Failed to resolve seed-data directory '{}'", seed_dir.display()))?;

        let read_dir = fs::read_dir(&seed_dir)
            .with_context(|| format!("Failed to read seed-data directory '{}'", seed_dir.display()))?;

        for entry in read_dir {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .context("Invalid seed data directory name")?
                .to_string();
            if name.starts_with('.') {
                continue;
            }

            println!("  {} Seeding initial state for '{}'", "+".cyan(), name);

            // Create tar.gz of this volume directory using the system tar binary
            let tar_output = std::process::Command::new("tar")
                .args([
                    "-czf",
                    "-",
                    "-C",
                    path.to_str().context("Non-UTF-8 path in seed data directory")?,
                    ".",
                ])
                .output()
                .with_context(|| format!("Failed to run tar for seed directory '{}'", name))?;

            if !tar_output.status.success() {
                let stderr = String::from_utf8_lossy(&tar_output.stderr);
                anyhow::bail!("tar failed for seed directory '{}': {}", name, stderr);
            }

            let tar_key = format!("_vibe_initial_state/{}.tar.gz", name);
            file_entries.insert(tar_key, tar_output.stdout);
        }
    }

    // Re-hash with the new files included
    let mut file_digests: BTreeMap<String, String> = BTreeMap::new();
    for (rel_path, contents) in &file_entries {
        let mut hasher = Sha256::new();
        hasher.update(contents);
        let hash = hex::encode(hasher.finalize());
        file_digests.insert(rel_path.clone(), hash);
    }

    // Build package manifest
    let pkg_manifest = PackageManifest {
        format_version: "1".to_string(),
        app_id: app_id.to_string(),
        app_version: app_version.to_string(),
        created_at: Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        files: file_digests,
    };
    let pkg_manifest_json = serde_json::to_string_pretty(&pkg_manifest)
        .context("Failed to serialize package manifest")?;

    // Determine output path
    let default_output = format!("{}-{}.vibeapp", app_id, app_version);
    let output_path = output.unwrap_or(Path::new(&default_output));

    // Build inner ZIP bytes in memory
    let zip_bytes = {
        let mut buf = Vec::new();
        let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        // Collect all entries: files + package manifest, sorted alphabetically
        let mut all_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        all_entries.insert(
            "_vibe_package_manifest.json".to_string(),
            pkg_manifest_json.as_bytes().to_vec(),
        );
        for (rel_path, contents) in &file_entries {
            all_entries.insert(rel_path.clone(), contents.clone());
        }

        for (name, contents) in &all_entries {
            zip.start_file(name, options)
                .with_context(|| format!("Failed to add '{}' to archive", name))?;
            zip.write_all(contents)
                .with_context(|| format!("Failed to write '{}' to archive", name))?;
        }
        zip.finish().context("Failed to finalize ZIP archive")?;
        buf
    };

    // Write (optionally encrypted) output
    crate::crypto::save_package(&zip_bytes, output_path, password, password_file)?;

    // Print summary
    let encrypted = password.is_some() || password_file.is_some();
    println!("{} Package created!", "✓".green().bold());
    println!("  {} {}", "Output:".dimmed(), output_path.display());
    println!("  {} {} ({})", "App:".dimmed(), app_id.cyan(), app_version);
    println!("  {} {} file(s)", "Files:".dimmed(), file_entries.len());
    if encrypted {
        println!("  {} {}", "Security:".dimmed(), "🔒 Encrypted".yellow());
    }

    Ok(())
}

fn collect_files(
    base: &Path,
    current: &Path,
    entries: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    let read_dir = fs::read_dir(current)
        .with_context(|| format!("Failed to read directory '{}'", current.display()))?;

    for entry in read_dir {
        let entry = entry?;
        let path = entry.path();

        // Skip hidden files/dirs and .vibeapp files
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if name.starts_with('.') || name.ends_with(".vibeapp") || name.ends_with(".sig") {
                continue;
            }
        }

        let rel_path = path
            .strip_prefix(base)
            .context("Failed to compute relative path")?
            .to_string_lossy()
            .replace('\\', "/");

        // Reject path traversal
        if rel_path.contains("..") {
            anyhow::bail!("Path traversal detected in '{}', aborting", rel_path);
        }

        if path.is_dir() {
            collect_files(base, &path, entries)?;
        } else {
            let contents =
                fs::read(&path).with_context(|| format!("Failed to read '{}'", path.display()))?;
            entries.insert(rel_path, contents);
        }
    }

    Ok(())
}

/// Minimal hex encoding to avoid adding a dependency.
mod hex {
    pub fn encode(bytes: impl AsRef<[u8]>) -> String {
        bytes
            .as_ref()
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect()
    }
}
