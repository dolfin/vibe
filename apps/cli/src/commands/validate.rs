use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;
use vibe_manifest::parse::parse_manifest_file;
use vibe_manifest::validate::validate_manifest;

pub fn run(manifest_path: &Path) -> Result<()> {
    println!(
        "Validating {}...",
        manifest_path.display().to_string().cyan()
    );

    let manifest = parse_manifest_file(manifest_path)
        .with_context(|| format!("Failed to parse manifest at '{}'", manifest_path.display()))?;

    match validate_manifest(&manifest) {
        Ok(()) => {
            println!("{} Manifest is valid!", "✓".green().bold());
            Ok(())
        }
        Err(errors) => {
            println!(
                "{} Manifest validation failed with {} error(s):",
                "✗".red().bold(),
                errors.len()
            );
            for err in &errors {
                println!("  {} {}", "•".red(), err);
            }
            anyhow::bail!("Manifest validation failed");
        }
    }
}
