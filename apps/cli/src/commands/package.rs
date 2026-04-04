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

    // Determine project directory (parent of manifest file).
    // Canonicalize the manifest path first so that a bare filename like "vibe.yaml"
    // (whose .parent() is "" rather than ".") resolves correctly against cwd.
    let manifest_path_abs = manifest_path.canonicalize().with_context(|| {
        format!(
            "Failed to resolve manifest path '{}'",
            manifest_path.display()
        )
    })?;
    let project_dir = manifest_path_abs
        .parent()
        .unwrap_or(&manifest_path_abs)
        .to_path_buf();

    // Load ignore patterns from .vibeignore (plus built-in defaults)
    let ignore_patterns = load_ignore_patterns(&project_dir);

    // Collect all files in the project directory
    let mut file_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut excluded_count: usize = 0;
    collect_files(
        &project_dir,
        &project_dir,
        &mut file_entries,
        &ignore_patterns,
        &mut excluded_count,
    )?;

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
        let seed_dir = seed_dir.canonicalize().with_context(|| {
            format!(
                "Failed to resolve seed-data directory '{}'",
                seed_dir.display()
            )
        })?;

        let read_dir = fs::read_dir(&seed_dir).with_context(|| {
            format!(
                "Failed to read seed-data directory '{}'",
                seed_dir.display()
            )
        })?;

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
            // Validate seed directory name: only lowercase letters, digits, hyphens, underscores.
            // This prevents null bytes, path separators, or other special characters from
            // causing issues when the name is used as a volume name or ZIP entry path.
            if !name
                .bytes()
                .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_'))
            {
                anyhow::bail!(
                    "Seed directory name '{}' is invalid: only a-z, 0-9, hyphens, and underscores are allowed",
                    name
                );
            }

            println!("  {} Seeding initial state for '{}'", "+".cyan(), name);

            // Create tar.gz of this volume directory using the system tar binary
            let tar_output = std::process::Command::new("tar")
                .args([
                    "-czf",
                    "-",
                    "-C",
                    path.to_str()
                        .context("Non-UTF-8 path in seed data directory")?,
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
    if excluded_count > 0 {
        println!(
            "  {} {} item(s) excluded via .vibeignore",
            "Excluded:".dimmed(),
            excluded_count
        );
    }
    if encrypted {
        println!("  {} {}", "Security:".dimmed(), "🔒 Encrypted".yellow());
    }

    Ok(())
}

/// Load ignore patterns from `.vibeignore` in the project root, prepended with
/// built-in defaults that are always excluded regardless of `.vibeignore`.
///
/// Pattern syntax:
/// - Lines starting with `#` and blank lines are ignored.
/// - A pattern **without** `/` (after stripping a trailing `/`) matches any
///   file or directory component at any depth (e.g. `node_modules`).
/// - A pattern **with** an interior `/` is matched against the relative path
///   from the project root (e.g. `dist/cache`).
/// - `*` matches any sequence of characters within a single path segment.
/// - `?` matches any single character.
fn load_ignore_patterns(project_dir: &Path) -> Vec<String> {
    // Built-in defaults — always excluded regardless of .vibeignore content.
    let mut patterns: Vec<String> = vec!["node_modules".to_string(), "target".to_string()];

    let ignore_file = project_dir.join(".vibeignore");
    if let Ok(contents) = fs::read_to_string(&ignore_file) {
        for line in contents.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            patterns.push(trimmed.to_string());
        }
    }

    patterns
}

/// Returns true if `rel_path` (e.g. `"src/foo/bar.ts"`) should be excluded.
fn is_ignored(rel_path: &str, patterns: &[String]) -> bool {
    for pattern in patterns {
        let p = pattern.trim_end_matches('/');
        if p.is_empty() {
            continue;
        }
        if p.contains('/') {
            // Pattern has an interior slash: match against the full relative path.
            if glob_match(p, rel_path) {
                return true;
            }
        } else {
            // No interior slash: match against each path component independently.
            for component in rel_path.split('/') {
                if glob_match(p, component) {
                    return true;
                }
            }
        }
    }
    false
}

/// Glob-style match supporting `*` (any sequence of chars) and `?` (any single char).
fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    glob_match_chars(&p, &t)
}

fn glob_match_chars(pattern: &[char], text: &[char]) -> bool {
    match (pattern, text) {
        ([], []) => true,
        ([], _) => false,
        (['*', p_rest @ ..], _) => {
            // * matches zero characters…
            if glob_match_chars(p_rest, text) {
                return true;
            }
            // …or one or more characters.
            if let Some((_, t_rest)) = text.split_first() {
                glob_match_chars(pattern, t_rest)
            } else {
                false
            }
        }
        (['?', p_rest @ ..], [_, t_rest @ ..]) => glob_match_chars(p_rest, t_rest),
        ([p, p_rest @ ..], [t, t_rest @ ..]) if p == t => glob_match_chars(p_rest, t_rest),
        _ => false,
    }
}

fn collect_files(
    base: &Path,
    current: &Path,
    entries: &mut BTreeMap<String, Vec<u8>>,
    patterns: &[String],
    excluded: &mut usize,
) -> Result<()> {
    let read_dir = fs::read_dir(current)
        .with_context(|| format!("Failed to read directory '{}'", current.display()))?;

    for entry in read_dir {
        let entry = entry?;
        let path = entry.path();

        // Skip hidden files/dirs and .vibeapp / .sig files
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

        // Reject path traversal via Path::components() — catches Unicode normalization
        // variants and redundant separators that a plain string `.contains("..")` would miss.
        if std::path::Path::new(&rel_path)
            .components()
            .any(|c| c == std::path::Component::ParentDir)
        {
            anyhow::bail!("Path traversal detected in '{}', aborting", rel_path);
        }

        // Prevent symlinks from packaging files or directories outside the project root.
        // canonicalize() follows the full symlink chain; starts_with(base) ensures the
        // resolved target remains within the project directory.
        if path.is_symlink() {
            let canonical = path
                .canonicalize()
                .with_context(|| format!("Failed to resolve symlink '{}'", path.display()))?;
            if !canonical.starts_with(base) {
                anyhow::bail!(
                    "Symlink '{}' points outside the project directory, aborting",
                    rel_path
                );
            }
        }

        // Check ignore patterns — prunes entire directories before recursing
        if is_ignored(&rel_path, patterns) {
            *excluded += 1;
            continue;
        }

        if path.is_dir() {
            collect_files(base, &path, entries, patterns, excluded)?;
        } else {
            let contents =
                fs::read(&path).with_context(|| format!("Failed to read '{}'", path.display()))?;
            entries.insert(rel_path, contents);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tempfile::tempdir;

    use crate::test_helpers::{
        assert_zip_contains, assert_zip_not_contains, random_test_password, read_zip_entry,
        write_minimal_project, write_password_file,
    };

    // ── run() tests ──────────────────────────────────────────────────────────

    #[test]
    fn creates_vibeapp_file() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert!(output.exists());
    }

    #[test]
    fn zip_contains_package_manifest() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_contains(&output, "_vibe_package_manifest.json");
    }

    #[test]
    fn zip_contains_app_manifest() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_contains(&output, "_vibe_app_manifest.json");
    }

    #[test]
    fn zip_contains_user_files() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_contains(&output, "index.html");
    }

    #[test]
    fn excludes_hidden_files() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        std::fs::write(dir.path().join(".secret"), b"secret").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_not_contains(&output, ".secret");
    }

    #[test]
    fn excludes_vibeapp_files() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        std::fs::write(dir.path().join("other.vibeapp"), b"dummy").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_not_contains(&output, "other.vibeapp");
    }

    #[test]
    fn excludes_sig_files() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        std::fs::write(dir.path().join("package.sig"), b"sig").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_not_contains(&output, "package.sig");
    }

    #[test]
    fn excludes_node_modules() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let nm = dir.path().join("node_modules");
        std::fs::create_dir(&nm).unwrap();
        std::fs::write(nm.join("package.json"), b"{}").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_not_contains(&output, "node_modules/package.json");
    }

    #[test]
    fn excludes_target_dir() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let tgt = dir.path().join("target/debug");
        std::fs::create_dir_all(&tgt).unwrap();
        std::fs::write(tgt.join("binary"), b"bin").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_not_contains(&output, "target/debug/binary");
    }

    #[test]
    fn respects_vibeignore_pattern() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        std::fs::write(dir.path().join(".vibeignore"), "*.log\n").unwrap();
        std::fs::write(dir.path().join("app.log"), b"logs").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        assert_zip_not_contains(&output, "app.log");
    }

    #[test]
    fn package_manifest_json_structure() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        let bytes = read_zip_entry(&output, "_vibe_package_manifest.json");
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert!(json["format_version"].is_string());
        assert!(json["app_id"].is_string());
        assert!(json["app_version"].is_string());
        assert!(json["created_at"].is_string());
        assert!(json["files"].is_object());
    }

    #[test]
    fn file_hashes_are_64_char_hex() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, None).unwrap();
        let bytes = read_zip_entry(&output, "_vibe_package_manifest.json");
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let files = json["files"].as_object().unwrap();
        for (_, hash) in files {
            let h = hash.as_str().unwrap();
            assert_eq!(h.len(), 64, "hash '{}' should be 64 chars", h);
            assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn with_password_creates_encrypted_output() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let output = dir.path().join("out.vibeapp");
        let pw = random_test_password();
        super::run(&manifest, Some(&output), None, Some(&pw), None).unwrap();
        assert!(crate::crypto::is_encrypted_package(&output));
    }

    #[test]
    fn with_password_file() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let pw = random_test_password();
        let pw_file = write_password_file(dir.path(), &pw);
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), None, None, Some(&pw_file)).unwrap();
        assert!(crate::crypto::is_encrypted_package(&output));
    }

    #[test]
    fn invalid_manifest_returns_err() {
        let dir = tempdir().unwrap();
        let manifest = dir.path().join("vibe.yaml");
        std::fs::write(&manifest, "kind: wrong/v1\n").unwrap();
        let output = dir.path().join("out.vibeapp");
        assert!(super::run(&manifest, Some(&output), None, None, None).is_err());
        assert!(!output.exists());
    }

    #[test]
    fn missing_manifest_returns_err() {
        let dir = tempdir().unwrap();
        let output = dir.path().join("out.vibeapp");
        let result = super::run(
            Path::new("/nonexistent/vibe.yaml"),
            Some(&output),
            None,
            None,
            None,
        );
        assert!(result.is_err());
    }

    #[test]
    fn with_seed_data_adds_initial_state() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let seed_dir = dir.path().join("seeds");
        let data_dir = seed_dir.join("data");
        std::fs::create_dir_all(&data_dir).unwrap();
        std::fs::write(data_dir.join("init.sql"), b"CREATE TABLE t (id int);").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), Some(&seed_dir), None, None).unwrap();
        assert_zip_contains(&output, "_vibe_initial_state/data.tar.gz");
    }

    #[test]
    fn seed_data_skips_hidden_dirs() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let seed_dir = dir.path().join("seeds");
        std::fs::create_dir_all(seed_dir.join(".hidden")).unwrap();
        std::fs::write(seed_dir.join(".hidden/file.txt"), b"x").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), Some(&seed_dir), None, None).unwrap();
        assert_zip_not_contains(&output, "_vibe_initial_state/.hidden.tar.gz");
    }

    #[test]
    fn seed_data_skips_top_level_files() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let seed_dir = dir.path().join("seeds");
        std::fs::create_dir_all(&seed_dir).unwrap();
        std::fs::write(seed_dir.join("readme.txt"), b"ignore me").unwrap();
        let output = dir.path().join("out.vibeapp");
        super::run(&manifest, Some(&output), Some(&seed_dir), None, None).unwrap();
        assert_zip_not_contains(&output, "_vibe_initial_state/readme.txt.tar.gz");
    }

    #[test]
    fn excluded_count_positive_with_ignored_items() {
        let dir = tempdir().unwrap();
        let manifest = write_minimal_project(dir.path(), "testapp");
        let nm = dir.path().join("node_modules");
        std::fs::create_dir(&nm).unwrap();
        std::fs::write(nm.join("index.js"), b"").unwrap();
        let output = dir.path().join("out.vibeapp");
        // Should succeed (excluded_count > 0 branch) without error
        assert!(super::run(&manifest, Some(&output), None, None, None).is_ok());
    }

    // ── glob_match tests ─────────────────────────────────────────────────────

    #[test]
    fn glob_exact_match() {
        assert!(super::glob_match("foo.txt", "foo.txt"));
    }

    #[test]
    fn glob_no_match() {
        assert!(!super::glob_match("foo.txt", "bar.txt"));
    }

    #[test]
    fn glob_star_matches_sequence() {
        assert!(super::glob_match("*.txt", "foo.txt"));
    }

    #[test]
    fn glob_star_matches_empty() {
        assert!(super::glob_match("*.txt", ".txt"));
    }

    #[test]
    fn glob_question_matches_one_char() {
        assert!(super::glob_match("f?o", "foo"));
        assert!(!super::glob_match("f?o", "fo"));
    }

    #[test]
    fn glob_star_only() {
        assert!(super::glob_match("*", "anything"));
        assert!(super::glob_match("*", ""));
    }

    #[test]
    fn glob_empty_both() {
        assert!(super::glob_match("", ""));
    }

    #[test]
    fn glob_empty_pattern_nonempty_text() {
        assert!(!super::glob_match("", "x"));
    }

    // ── is_ignored tests ─────────────────────────────────────────────────────

    #[test]
    fn is_ignored_name_matches_any_depth() {
        let patterns = vec!["node_modules".to_string()];
        assert!(super::is_ignored("sub/node_modules", &patterns));
        assert!(super::is_ignored("sub/node_modules/pkg.json", &patterns));
    }

    #[test]
    fn is_ignored_slash_pattern_full_path() {
        let patterns = vec!["dist/cache".to_string()];
        assert!(super::is_ignored("dist/cache", &patterns));
        assert!(!super::is_ignored("src/cache", &patterns));
    }

    #[test]
    fn is_ignored_trailing_slash_stripped() {
        let patterns = vec!["node_modules/".to_string()];
        assert!(super::is_ignored("node_modules", &patterns));
    }

    // ── load_ignore_patterns tests ───────────────────────────────────────────

    #[test]
    fn load_patterns_defaults_only() {
        let dir = tempdir().unwrap();
        let patterns = super::load_ignore_patterns(dir.path());
        assert_eq!(patterns, vec!["node_modules", "target"]);
    }

    #[test]
    fn load_patterns_appends_vibeignore() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join(".vibeignore"), "*.log\n# comment\n\n").unwrap();
        let patterns = super::load_ignore_patterns(dir.path());
        assert_eq!(patterns.len(), 3);
        assert_eq!(patterns[0], "node_modules");
        assert_eq!(patterns[1], "target");
        assert_eq!(patterns[2], "*.log");
    }
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
