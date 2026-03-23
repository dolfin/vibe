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

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tempfile::tempdir;

    use crate::test_helpers::write_minimal_project;

    #[test]
    fn valid_manifest_ok() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        assert!(super::run(&manifest).is_ok());
    }

    #[test]
    fn invalid_kind_err() {
        let dir = tempdir().unwrap();
        let manifest = dir.path().join("vibe.yaml");
        std::fs::write(
            &manifest,
            "kind: wrong/v1\nid: com.example.app\nname: App\nversion: 1.0.0\nservices:\n  - name: web\n    image: nginx\n",
        )
        .unwrap();
        assert!(super::run(&manifest).is_err());
    }

    #[test]
    fn missing_services_err() {
        let dir = tempdir().unwrap();
        let manifest = dir.path().join("vibe.yaml");
        std::fs::write(
            &manifest,
            "kind: vibe.app/v1\nid: com.example.app\nname: App\nversion: 1.0.0\n",
        )
        .unwrap();
        assert!(super::run(&manifest).is_err());
    }

    #[test]
    fn nonexistent_file_err() {
        let result = super::run(Path::new("/nonexistent/vibe.yaml"));
        assert!(result.is_err());
    }

    #[test]
    fn invalid_yaml_syntax_err() {
        let dir = tempdir().unwrap();
        let manifest = dir.path().join("vibe.yaml");
        std::fs::write(&manifest, ": :::").unwrap();
        assert!(super::run(&manifest).is_err());
    }
}
