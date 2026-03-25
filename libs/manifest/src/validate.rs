use std::collections::{HashMap, HashSet};

use crate::Manifest;

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum ValidationError {
    #[error("missing required field: {0}")]
    MissingField(String),

    #[error("invalid kind: expected 'vibe.app/v1', got '{0}'")]
    InvalidKind(String),

    #[error("invalid semver version: {0}")]
    InvalidVersion(String),

    #[error("duplicate service name: {0}")]
    DuplicateServiceName(String),

    #[error("invalid service name '{0}': must match [a-z0-9-]")]
    InvalidServiceName(String),

    #[error("path traversal detected in {field}: {path}")]
    PathTraversal { field: String, path: String },

    #[error("absolute path not allowed in {field}: {path}")]
    AbsolutePath { field: String, path: String },

    #[error("service '{service}' depends on unknown service '{dependency}'")]
    UnknownDependency { service: String, dependency: String },

    #[error("dependency cycle detected involving service: {0}")]
    DependencyCycle(String),

    #[error("invalid port number {port} in service '{service}': must be 1-65535")]
    InvalidPort { service: String, port: u16 },

    #[error("service '{service}' references undeclared volume: {volume}")]
    UndeclaredVolume { service: String, volume: String },

    #[error("field '{field}' exceeds maximum length of {max} characters")]
    FieldTooLong { field: String, max: usize },

    #[error("invalid image name in service '{service}': {reason}")]
    InvalidImage { service: String, reason: String },

    #[error("too many {field}: maximum is {max}")]
    TooMany { field: String, max: usize },

    #[error("invalid env var name '{name}' in service '{service}': must match [A-Z_][A-Z0-9_]*")]
    InvalidEnvVarName { service: String, name: String },
}

/// Validate a parsed manifest, returning all discovered errors.
pub fn validate_manifest(manifest: &Manifest) -> Result<(), Vec<ValidationError>> {
    let mut errors = Vec::new();

    // Check kind
    if manifest.kind != "vibe.app/v1" {
        errors.push(ValidationError::InvalidKind(manifest.kind.clone()));
    }

    // Check required fields
    if manifest.id.is_none() {
        errors.push(ValidationError::MissingField("id".into()));
    }
    if manifest.name.is_none() {
        errors.push(ValidationError::MissingField("name".into()));
    }
    if manifest.version.is_none() {
        errors.push(ValidationError::MissingField("version".into()));
    }

    // Validate semver
    if let Some(ref v) = manifest.version {
        if semver::Version::parse(v).is_err() {
            errors.push(ValidationError::InvalidVersion(v.clone()));
        }
    }

    // String length limits for top-level fields
    const MAX_ID_LEN: usize = 256;
    const MAX_NAME_LEN: usize = 256;
    const MAX_IMAGE_LEN: usize = 512;
    const MAX_COMMAND_ELEMENT_LEN: usize = 2048;
    const MAX_ENV_VALUE_LEN: usize = 4096;
    const MAX_SERVICES: usize = 20;
    const MAX_MOUNTS: usize = 50;
    const MAX_ENV_VARS: usize = 100;

    if let Some(ref id) = manifest.id {
        if id.len() > MAX_ID_LEN {
            errors.push(ValidationError::FieldTooLong { field: "id".into(), max: MAX_ID_LEN });
        }
    }
    if let Some(ref name) = manifest.name {
        if name.len() > MAX_NAME_LEN {
            errors.push(ValidationError::FieldTooLong { field: "name".into(), max: MAX_NAME_LEN });
        }
    }

    // Must have at least one service
    let services = match &manifest.services {
        Some(s) if !s.is_empty() => s,
        _ => {
            errors.push(ValidationError::MissingField("services".into()));
            if errors.is_empty() {
                return Ok(());
            }
            return Err(errors);
        }
    };

    // Collection size limits
    if services.len() > MAX_SERVICES {
        errors.push(ValidationError::TooMany { field: "services".into(), max: MAX_SERVICES });
    }

    // Validate icon path
    if let Some(ref icon) = manifest.icon {
        if icon.contains("..") {
            errors.push(ValidationError::PathTraversal {
                field: "icon".into(),
                path: icon.clone(),
            });
        }
    }

    // Collect service names for reference validation
    let service_names: HashSet<&str> = services.iter().map(|s| s.name.as_str()).collect();

    // Collect declared state volume names
    let declared_volumes: HashSet<&str> = manifest
        .state
        .as_ref()
        .and_then(|s| s.volumes.as_ref())
        .map(|vols| vols.iter().map(|v| v.name.as_str()).collect())
        .unwrap_or_default();

    // Check for duplicate service names
    let mut seen_names = HashSet::new();
    for svc in services {
        if !seen_names.insert(&svc.name) {
            errors.push(ValidationError::DuplicateServiceName(svc.name.clone()));
        }
    }

    let name_re_valid = |name: &str| -> bool {
        !name.is_empty()
            && name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    };

    for svc in services {
        // Validate service name characters
        if !name_re_valid(&svc.name) {
            errors.push(ValidationError::InvalidServiceName(svc.name.clone()));
        }

        // Validate image name: reject null bytes, enforce length, require printable ASCII
        if let Some(ref image) = svc.image {
            if image.len() > MAX_IMAGE_LEN {
                errors.push(ValidationError::FieldTooLong {
                    field: format!("service '{}' image", svc.name),
                    max: MAX_IMAGE_LEN,
                });
            } else if image.contains('\0') || image.chars().any(|c| c.is_control()) {
                errors.push(ValidationError::InvalidImage {
                    service: svc.name.clone(),
                    reason: "contains control characters or null bytes".into(),
                });
            } else if image.trim().is_empty() {
                errors.push(ValidationError::InvalidImage {
                    service: svc.name.clone(),
                    reason: "image name must not be empty".into(),
                });
            }
        }

        // Validate command element lengths
        if let Some(ref cmd) = svc.command {
            for element in cmd {
                if element.len() > MAX_COMMAND_ELEMENT_LEN {
                    errors.push(ValidationError::FieldTooLong {
                        field: format!("service '{}' command element", svc.name),
                        max: MAX_COMMAND_ELEMENT_LEN,
                    });
                }
            }
        }

        // Validate env var names and value lengths
        if let Some(ref env) = svc.env {
            if env.len() > MAX_ENV_VARS {
                errors.push(ValidationError::TooMany {
                    field: format!("service '{}' env vars", svc.name),
                    max: MAX_ENV_VARS,
                });
            }
            let env_key_valid = |k: &str| -> bool {
                !k.is_empty()
                    && k.chars().next().is_some_and(|c| c.is_ascii_uppercase() || c == '_')
                    && k.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
            };
            for (key, value) in env {
                if !env_key_valid(key) {
                    errors.push(ValidationError::InvalidEnvVarName {
                        service: svc.name.clone(),
                        name: key.clone(),
                    });
                }
                if value.len() > MAX_ENV_VALUE_LEN {
                    errors.push(ValidationError::FieldTooLong {
                        field: format!("service '{}' env var '{}'", svc.name, key),
                        max: MAX_ENV_VALUE_LEN,
                    });
                }
            }
        }

        // Validate ports
        if let Some(ref ports) = svc.ports {
            for port in ports {
                if port.container == 0 {
                    errors.push(ValidationError::InvalidPort {
                        service: svc.name.clone(),
                        port: port.container,
                    });
                }
            }
        }

        // Validate mount paths for traversal and absolute paths
        if let Some(ref mounts) = svc.mounts {
            if mounts.len() > MAX_MOUNTS {
                errors.push(ValidationError::TooMany {
                    field: format!("service '{}' mounts", svc.name),
                    max: MAX_MOUNTS,
                });
            }
            for mount in mounts {
                if mount.source.starts_with('/') {
                    errors.push(ValidationError::AbsolutePath {
                        field: format!("service '{}' mount source", svc.name),
                        path: mount.source.clone(),
                    });
                } else if mount.source.contains("..") {
                    errors.push(ValidationError::PathTraversal {
                        field: format!("service '{}' mount source", svc.name),
                        path: mount.source.clone(),
                    });
                }
                if mount.target.contains("..") {
                    errors.push(ValidationError::PathTraversal {
                        field: format!("service '{}' mount target", svc.name),
                        path: mount.target.clone(),
                    });
                }
            }
        }

        // Validate dependency references
        if let Some(ref deps) = svc.depend_on {
            for dep in deps {
                if !service_names.contains(dep.as_str()) {
                    errors.push(ValidationError::UnknownDependency {
                        service: svc.name.clone(),
                        dependency: dep.clone(),
                    });
                }
            }
        }

        // Validate volume references
        if let Some(ref vols) = svc.state_volumes {
            for vol in vols {
                if !declared_volumes.contains(vol.volume_name.as_str()) {
                    errors.push(ValidationError::UndeclaredVolume {
                        service: svc.name.clone(),
                        volume: vol.volume_name.clone(),
                    });
                }
            }
        }
    }

    // Detect dependency cycles via DFS
    let dep_map: HashMap<&str, Vec<&str>> = services
        .iter()
        .map(|s| {
            let deps = s
                .depend_on
                .as_ref()
                .map(|d| d.iter().map(|x| x.as_str()).collect())
                .unwrap_or_default();
            (s.name.as_str(), deps)
        })
        .collect();

    // DFS cycle detection
    {
        #[derive(Clone, Copy, PartialEq)]
        enum Color {
            White,
            Gray,
            Black,
        }

        let mut color: HashMap<&str, Color> =
            service_names.iter().map(|&n| (n, Color::White)).collect();

        fn dfs<'a>(
            node: &'a str,
            dep_map: &HashMap<&'a str, Vec<&'a str>>,
            color: &mut HashMap<&'a str, Color>,
            errors: &mut Vec<ValidationError>,
        ) {
            color.insert(node, Color::Gray);
            if let Some(deps) = dep_map.get(node) {
                for &dep in deps {
                    match color.get(dep) {
                        Some(Color::Gray) => {
                            errors.push(ValidationError::DependencyCycle(dep.to_string()));
                        }
                        Some(Color::White) | None => {
                            if color.get(dep) == Some(&Color::White) {
                                dfs(dep, dep_map, color, errors);
                            }
                        }
                        Some(Color::Black) => {}
                    }
                }
            }
            color.insert(node, Color::Black);
        }

        for &name in &service_names {
            if color.get(name) == Some(&Color::White) {
                dfs(name, &dep_map, &mut color, &mut errors);
            }
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::parse_manifest;

    fn load_testdata(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join(name);
        std::fs::read_to_string(path).unwrap()
    }

    #[test]
    fn test_valid_minimal() {
        let yaml = load_testdata("valid_minimal.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        assert!(validate_manifest(&manifest).is_ok());
    }

    #[test]
    fn test_valid_full() {
        let yaml = load_testdata("valid_full.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        assert!(validate_manifest(&manifest).is_ok());
    }

    #[test]
    fn test_missing_id() {
        let yaml = load_testdata("invalid_missing_id.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::MissingField(f) if f == "id")));
    }

    #[test]
    fn test_bad_version() {
        let yaml = load_testdata("invalid_bad_version.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::InvalidVersion(_))));
    }

    #[test]
    fn test_path_traversal() {
        let yaml = load_testdata("invalid_path_traversal.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::PathTraversal { .. })));
    }

    #[test]
    fn test_duplicate_service() {
        let yaml = load_testdata("invalid_duplicate_service.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::DuplicateServiceName(_))));
    }

    #[test]
    fn test_dependency_cycle() {
        let yaml = load_testdata("invalid_dependency_cycle.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::DependencyCycle(_))));
    }

    #[test]
    fn test_missing_volume() {
        let yaml = load_testdata("invalid_missing_volume.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::UndeclaredVolume { .. })));
    }

    #[test]
    fn test_bad_kind() {
        let yaml = load_testdata("invalid_bad_kind.yaml");
        let manifest = parse_manifest(&yaml).unwrap();
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::InvalidKind(_))));
    }

    #[test]
    fn test_invalid_service_name() {
        let manifest = Manifest {
            kind: "vibe.app/v1".into(),
            id: Some("com.test.app".into()),
            name: Some("Test".into()),
            version: Some("1.0.0".into()),
            icon: None,
            runtime: None,
            services: Some(vec![crate::Service {
                name: "INVALID_NAME".into(),
                image: Some("test:1".into()),
                command: None,
                env: None,
                ports: None,
                mounts: None,
                state_volumes: None,
                depend_on: None,
            }]),
            state: None,
            security: None,
            secrets: None,
            publisher: None,
            ui: None,
        };
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::InvalidServiceName(_))));
    }

    #[test]
    fn test_unknown_dependency() {
        let manifest = Manifest {
            kind: "vibe.app/v1".into(),
            id: Some("com.test.app".into()),
            name: Some("Test".into()),
            version: Some("1.0.0".into()),
            icon: None,
            runtime: None,
            services: Some(vec![crate::Service {
                name: "web".into(),
                image: Some("test:1".into()),
                command: None,
                env: None,
                ports: None,
                mounts: None,
                state_volumes: None,
                depend_on: Some(vec!["nonexistent".into()]),
            }]),
            state: None,
            security: None,
            secrets: None,
            publisher: None,
            ui: None,
        };
        let errs = validate_manifest(&manifest).unwrap_err();
        assert!(errs
            .iter()
            .any(|e| matches!(e, ValidationError::UnknownDependency { .. })));
    }
}
