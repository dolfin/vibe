pub mod parse;
pub mod validate;

use serde::{Deserialize, Serialize};

/// Top-level manifest structure for a Vibe application.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub services: Option<Vec<Service>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<StateConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub security: Option<SecurityConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secrets: Option<Vec<Secret>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui: Option<UiConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publisher: Option<PublisherConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeConfig {
    pub mode: RuntimeMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compose_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeMode {
    Native,
    Compose,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Service {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<std::collections::HashMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ports: Option<Vec<Port>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mounts: Option<Vec<Mount>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_volumes: Option<Vec<StateVolumeMapping>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub depend_on: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Port {
    pub container: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_exposure: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Mount {
    pub source: String,
    pub target: String,
}

/// A volume mapping in the format "name:/path" serialized as a string.
#[derive(Debug, Clone, PartialEq)]
pub struct StateVolumeMapping {
    pub volume_name: String,
    pub mount_path: String,
}

impl Serialize for StateVolumeMapping {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let s = format!("{}:{}", self.volume_name, self.mount_path);
        serializer.serialize_str(&s)
    }
}

impl<'de> Deserialize<'de> for StateVolumeMapping {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        let parts: Vec<&str> = s.splitn(2, ':').collect();
        if parts.len() != 2 {
            return Err(serde::de::Error::custom(format!(
                "invalid state volume mapping: '{}', expected format 'name:/path'",
                s
            )));
        }
        Ok(StateVolumeMapping {
            volume_name: parts[0].to_string(),
            mount_path: parts[1].to_string(),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StateConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub autosave: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub autosave_debounce_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retention: Option<RetentionPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volumes: Option<Vec<Volume>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RetentionPolicy {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_snapshots: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Volume {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consistency: Option<VolumeConsistency>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum VolumeConsistency {
    Generic,
    Sqlite,
    Postgres,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SecurityConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allow_host_file_import: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Secret {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub how_to_obtain: Option<String>,
}

/// Browser chrome options for the app's embedded WebView.
/// All fields default to `false`; omitting `ui` entirely is equivalent to all false.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UiConfig {
    /// Show a back-navigation button.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_back_button: Option<bool>,
    /// Show a forward-navigation button.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_forward_button: Option<bool>,
    /// Show a reload / stop-loading button.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_reload_button: Option<bool>,
    /// Show a home button that returns to the app's root URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_home_button: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PublisherConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signing: Option<SigningConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SigningConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheme: Option<SigningScheme>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_key_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum SigningScheme {
    Ed25519,
}
