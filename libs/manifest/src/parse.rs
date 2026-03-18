use std::path::Path;

use crate::Manifest;

/// Maximum allowed manifest size (1 MB). Prevents YAML bomb / memory exhaustion.
const MAX_MANIFEST_BYTES: usize = 1_000_000;

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("YAML parse error: {0}")]
    Yaml(#[from] serde_yaml::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("manifest exceeds maximum allowed size of {MAX_MANIFEST_BYTES} bytes")]
    TooLarge,
}

/// Parse a manifest from a YAML string.
pub fn parse_manifest(yaml: &str) -> Result<Manifest, ParseError> {
    if yaml.len() > MAX_MANIFEST_BYTES {
        return Err(ParseError::TooLarge);
    }
    let manifest: Manifest = serde_yaml::from_str(yaml)?;
    Ok(manifest)
}

/// Serialize a manifest to a YAML string.
pub fn serialize_manifest(manifest: &Manifest) -> Result<String, ParseError> {
    let yaml = serde_yaml::to_string(manifest)?;
    Ok(yaml)
}

/// Serialize a manifest to a pretty-printed JSON string.
pub fn serialize_manifest_json(manifest: &Manifest) -> Result<String, ParseError> {
    Ok(serde_json::to_string_pretty(manifest)?)
}

/// Parse a manifest from a YAML file on disk.
pub fn parse_manifest_file(path: &Path) -> Result<Manifest, ParseError> {
    let content = std::fs::read_to_string(path)?;
    parse_manifest(&content)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load_testdata(name: &str) -> String {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join(name);
        std::fs::read_to_string(path).unwrap()
    }

    #[test]
    fn test_parse_minimal() {
        let yaml = load_testdata("valid_minimal.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        assert_eq!(manifest.kind, "vibe.app/v1");
        assert_eq!(manifest.id.as_deref(), Some("com.example.minimal"));
        assert_eq!(manifest.name.as_deref(), Some("Minimal App"));
        assert!(manifest.services.is_some());
        assert_eq!(manifest.services.as_ref().unwrap().len(), 1);
    }

    #[test]
    fn test_parse_full() {
        let yaml = load_testdata("valid_full.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        assert_eq!(manifest.kind, "vibe.app/v1");
        assert_eq!(manifest.id.as_deref(), Some("com.example.todo"));
        assert!(manifest.services.as_ref().unwrap().len() >= 2);
        assert!(manifest.state.is_some());
        assert!(manifest.security.is_some());
        assert!(manifest.secrets.is_some());
        assert!(manifest.publisher.is_some());
    }

    #[test]
    fn test_round_trip() {
        let yaml = load_testdata("valid_full.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let serialized = serialize_manifest(&manifest).unwrap();
        let manifest2 = parse_manifest(&serialized).unwrap();
        assert_eq!(manifest, manifest2);
    }

    #[test]
    fn test_parse_file() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join("valid_minimal.yaml");
        let manifest = parse_manifest_file(&path).unwrap();
        assert_eq!(manifest.kind, "vibe.app/v1");
    }

    #[test]
    fn test_parse_nonexistent_file() {
        let result = parse_manifest_file(Path::new("/nonexistent/path.yaml"));
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_invalid_yaml() {
        let result = parse_manifest("not: [valid: yaml: {{{}}}");
        assert!(result.is_err());
    }

    #[test]
    fn test_state_volume_mapping_round_trip() {
        let yaml = load_testdata("valid_full.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let db_service = manifest
            .services
            .as_ref()
            .unwrap()
            .iter()
            .find(|s| s.name == "db")
            .unwrap();
        let vols = db_service.state_volumes.as_ref().unwrap();
        assert_eq!(vols[0].volume_name, "dbdata");
        assert_eq!(vols[0].mount_path, "/var/lib/postgresql/data");
    }
}
