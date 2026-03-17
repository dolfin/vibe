use std::io::{Read, Write};
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

/// Strip `_vibe_state/*` entries from a .vibeapp, restoring it to its original signed state.
pub fn run(package: &Path) -> Result<()> {
    println!(
        "Reverting {}...",
        package.display().to_string().cyan()
    );

    let data = std::fs::read(package)
        .with_context(|| format!("Failed to read '{}'", package.display()))?;

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

    // Write new ZIP to a temp file, then atomically rename
    let tmp_path = package.with_extension("vibeapp.tmp");
    let tmp_file = std::fs::File::create(&tmp_path)
        .with_context(|| format!("Failed to create temp file '{}'", tmp_path.display()))?;
    let mut zip = ZipWriter::new(tmp_file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

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

    // Atomic rename
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
