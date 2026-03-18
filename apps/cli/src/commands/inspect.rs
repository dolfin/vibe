use std::io::Read;
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use zip::read::ZipArchive;

pub fn run(
    package_path: &Path,
    password: Option<&str>,
    password_file: Option<&Path>,
) -> Result<()> {
    println!(
        "Inspecting {}...\n",
        package_path.display().to_string().cyan()
    );

    let is_encrypted = crate::crypto::is_encrypted_package(package_path);
    if is_encrypted {
        println!("{} Encrypted package", "🔒".yellow());
    }

    let zip_data = crate::crypto::open_package(package_path, password, password_file)?;

    let cursor = std::io::Cursor::new(&zip_data);
    let mut archive = ZipArchive::new(cursor).context("Failed to open package as ZIP archive")?;

    // Try to extract and display package manifest
    let has_manifest = archive.by_name("_vibe_package_manifest.json").is_ok();
    let has_signature = archive.by_name("_vibe_signature.sig").is_ok();

    if has_manifest {
        let mut file = archive.by_name("_vibe_package_manifest.json").unwrap();
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;

        let parsed: serde_json::Value =
            serde_json::from_str(&contents).context("Failed to parse package manifest")?;
        let pretty =
            serde_json::to_string_pretty(&parsed).context("Failed to format package manifest")?;

        println!("{}", "Package Manifest:".bold());
        println!("{}", pretty);
        println!();
    } else {
        println!(
            "{} No _vibe_package_manifest.json found",
            "!".yellow().bold()
        );
    }

    // List all files with sizes
    println!("{}", "Files:".bold());
    for i in 0..archive.len() {
        let file = archive.by_index(i)?;
        let name = file.name().to_string();
        let size = file.size();

        let display_name = if name == "_vibe_package_manifest.json" || name == "_vibe_signature.sig"
        {
            name.dimmed().to_string()
        } else {
            name.to_string()
        };

        println!("  {:>8}  {}", format_size(size), display_name);
    }

    println!();

    // Show signature status
    if has_signature {
        println!("{} Package is signed", "✓".green().bold());
    } else {
        println!("{} Package is NOT signed", "!".yellow().bold());
    }

    Ok(())
}

fn format_size(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}
