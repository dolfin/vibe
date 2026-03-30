/// Shared test utilities for CLI command tests.
/// Declared in lib.rs as `#[cfg(test)] pub(crate) mod test_helpers;`
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use zip::write::SimpleFileOptions;
use zip::ZipWriter;

// ── Minimal project helpers ───────────────────────────────────────────────────

/// A valid vibe.app/v1 manifest YAML with an nginx service.
/// `name` is used as both the app display name and the last segment of the id.
pub fn minimal_manifest_yaml(name: &str) -> String {
    format!(
        "kind: vibe.app/v1\n\
         id: com.example.{name}\n\
         name: {name}\n\
         version: 0.1.0\n\
         \n\
         services:\n\
           - name: web\n\
             image: nginx:alpine\n\
             ports:\n\
               - container: 80\n"
    )
}

/// Write a minimal valid project (vibe.yaml + index.html) into `dir`.
/// Returns the path to the vibe.yaml file.
pub fn write_minimal_project(dir: &Path, name: &str) -> PathBuf {
    let manifest_path = dir.join("vibe.yaml");
    fs::write(&manifest_path, minimal_manifest_yaml(name)).unwrap();
    fs::write(dir.join("index.html"), b"<html><body>Hello</body></html>").unwrap();
    manifest_path
}

// ── Package / sign helpers ────────────────────────────────────────────────────

/// Package `manifest` to `output` (unencrypted, unsigned).
pub fn build_package(manifest: &Path, output: &Path) {
    crate::commands::package::run(manifest, Some(output), None, None, None).unwrap();
}

/// Package + keygen + sign. Returns (key_path, pub_path).
pub fn build_signed_package(manifest: &Path, output: &Path) -> (PathBuf, PathBuf) {
    build_package(manifest, output);
    let dir = output.parent().unwrap();
    let prefix = dir.join("_signing").to_str().unwrap().to_string();
    crate::commands::keygen::run(&prefix).unwrap();
    let key_path = PathBuf::from(format!("{}.key", prefix));
    let pub_path = PathBuf::from(format!("{}.pub", prefix));
    crate::commands::sign::run(output, &key_path, None, None, false).unwrap();
    (key_path, pub_path)
}

/// Package `manifest` to `output` encrypted with `pw`.
pub fn build_encrypted_package(manifest: &Path, output: &Path, pw: &str) {
    crate::commands::package::run(manifest, Some(output), None, Some(pw), None).unwrap();
}

/// Package + keygen + sign (encrypted). Returns (key_path, pub_path).
pub fn build_encrypted_signed_package(
    manifest: &Path,
    output: &Path,
    pw: &str,
) -> (PathBuf, PathBuf) {
    build_encrypted_package(manifest, output, pw);
    let dir = output.parent().unwrap();
    let prefix = dir.join("_signing").to_str().unwrap().to_string();
    crate::commands::keygen::run(&prefix).unwrap();
    let key_path = PathBuf::from(format!("{}.key", prefix));
    let pub_path = PathBuf::from(format!("{}.pub", prefix));
    crate::commands::sign::run(output, &key_path, Some(pw), None, false).unwrap();
    (key_path, pub_path)
}

// ── ZIP helpers ───────────────────────────────────────────────────────────────

/// Build a raw ZIP in memory from (name, bytes) pairs.
pub fn make_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));
    let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for (name, content) in entries {
        zip.start_file(*name, opts).unwrap();
        zip.write_all(content).unwrap();
    }
    zip.finish().unwrap();
    buf
}

/// Panics if `entry` is not present in the ZIP at `path`.
pub fn assert_zip_contains(path: &Path, entry: &str) {
    let data = fs::read(path).unwrap_or_else(|e| panic!("read {:?}: {}", path, e));
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data))
        .unwrap_or_else(|e| panic!("open ZIP {:?}: {}", path, e));
    assert!(
        archive.by_name(entry).is_ok(),
        "expected ZIP entry '{}' in {:?}",
        entry,
        path
    );
}

/// Panics if `entry` IS present in the ZIP at `path`.
pub fn assert_zip_not_contains(path: &Path, entry: &str) {
    let data = fs::read(path).unwrap_or_else(|e| panic!("read {:?}: {}", path, e));
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data))
        .unwrap_or_else(|e| panic!("open ZIP {:?}: {}", path, e));
    assert!(
        archive.by_name(entry).is_err(),
        "unexpected ZIP entry '{}' found in {:?}",
        entry,
        path
    );
}

/// Returns the raw bytes of `entry` from the ZIP at `path`.
pub fn read_zip_entry(path: &Path, entry: &str) -> Vec<u8> {
    use std::io::Read as _;
    let data = fs::read(path).unwrap();
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data)).unwrap();
    let mut file = archive
        .by_name(entry)
        .unwrap_or_else(|_| panic!("entry '{}' not found in {:?}", entry, path));
    let mut contents = Vec::new();
    file.read_to_end(&mut contents).unwrap();
    contents
}

/// Write `password` to `<dir>/password.txt` and return the path.
pub fn write_password_file(dir: &Path, password: &str) -> PathBuf {
    let path = dir.join("password.txt");
    fs::write(&path, password).unwrap();
    path
}
