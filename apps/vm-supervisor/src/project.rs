//! Project lifecycle manager — extracts .vibeapp packages, starts/stops Docker containers.

use std::collections::HashMap;
use std::io::Read;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::RwLock;

use serde::{Deserialize, Serialize};
use vibe_container_runtime::{ContainerSpec, DockerClient, PortMapping, VolumeMount};
use vibe_manifest::Manifest;

#[derive(Debug, thiserror::Error)]
pub enum ProjectError {
    #[error("project not found: {0}")]
    NotFound(String),
    #[error("docker error: {0}")]
    Docker(#[from] vibe_container_runtime::DockerError),
    #[error("package error: {0}")]
    Package(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, ProjectError>;

/// Runtime state of a managed project.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedProject {
    pub id: String,
    pub app_id: String,
    pub app_name: String,
    pub app_version: String,
    pub status: ProjectStatus,
    pub services: Vec<ServiceState>,
    pub network_name: String,
    /// Directory where the .vibeapp contents are extracted.
    pub extract_dir: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ProjectStatus {
    Stopped,
    Starting,
    Running,
    Stopping,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceState {
    pub name: String,
    pub image: String,
    pub command: Vec<String>,
    pub container_name: String,
    pub container_port: u16,
    pub host_port: u16,
    pub running: bool,
}

/// Thread-safe project manager.
#[derive(Clone)]
pub struct ProjectManager {
    projects: Arc<RwLock<HashMap<String, ManagedProject>>>,
}

impl ProjectManager {
    pub fn new() -> Self {
        Self {
            projects: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Import a .vibeapp package and register the project (does not start it).
    pub async fn import_package(&self, package_path: &Path) -> Result<ManagedProject> {
        // Read and extract the package
        let data =
            std::fs::read(package_path).map_err(|e| ProjectError::Package(e.to_string()))?;
        let manifest = extract_manifest(&data)?;

        let app_id = manifest.id.as_deref().unwrap_or("unknown").to_string();
        let app_name = manifest
            .name
            .as_deref()
            .unwrap_or("Unnamed")
            .to_string();
        let app_version = manifest.version.as_deref().unwrap_or("0.0.0").to_string();

        let project_id = format!("vibe-{}", uuid::Uuid::new_v4().as_simple());
        let network_name = format!("vibe-net-{}", &project_id[5..13]);

        // Extract package contents to a working directory
        let extract_dir = std::env::temp_dir()
            .join("vibe-projects")
            .join(&project_id);
        extract_package_files(&data, &extract_dir)?;
        tracing::info!("Extracted package to {}", extract_dir.display());

        // Build service states from manifest
        let mut services = Vec::new();
        for svc in manifest.services.as_deref().unwrap_or_default() {
            let image = svc.image.as_deref().unwrap_or("alpine:latest").to_string();
            let command = svc.command.clone().unwrap_or_default();
            let container_port = svc
                .ports
                .as_ref()
                .and_then(|p| p.first())
                .map(|p| p.container)
                .unwrap_or(0);

            // Find an available host port
            let host_port = if container_port > 0 {
                DockerClient::find_available_port(container_port).await
            } else {
                0
            };

            let container_name = format!("{}-{}", project_id, svc.name);

            services.push(ServiceState {
                name: svc.name.clone(),
                image,
                command,
                container_name,
                container_port,
                host_port,
                running: false,
            });
        }

        let project = ManagedProject {
            id: project_id.clone(),
            app_id,
            app_name,
            app_version,
            status: ProjectStatus::Stopped,
            services,
            network_name,
            extract_dir: extract_dir.to_string_lossy().to_string(),
        };

        self.projects
            .write()
            .await
            .insert(project_id, project.clone());
        Ok(project)
    }

    /// Start all services for a project.
    pub async fn start_project(&self, project_id: &str) -> Result<ManagedProject> {
        // Check Docker first
        DockerClient::check().await?;

        // Get project
        let project = {
            let projects = self.projects.read().await;
            projects
                .get(project_id)
                .cloned()
                .ok_or_else(|| ProjectError::NotFound(project_id.to_string()))?
        };

        // Update status to starting
        {
            let mut projects = self.projects.write().await;
            if let Some(p) = projects.get_mut(project_id) {
                p.status = ProjectStatus::Starting;
            }
        }

        // Create network
        DockerClient::create_network(&project.network_name).await?;

        // Re-resolve host ports at start time (they may have been taken since import)
        {
            let mut projects = self.projects.write().await;
            if let Some(p) = projects.get_mut(project_id) {
                for svc in &mut p.services {
                    if svc.container_port > 0 {
                        svc.host_port =
                            DockerClient::find_available_port(svc.container_port).await;
                        tracing::info!(
                            "Resolved port for {}: {} -> {}",
                            svc.name,
                            svc.container_port,
                            svc.host_port
                        );
                    }
                }
            }
        }

        // Re-read project with updated ports
        let project = {
            let projects = self.projects.read().await;
            projects.get(project_id).cloned().unwrap()
        };

        // Start containers in dependency order (for now, sequential)
        for svc in &project.services {
            // Pull image
            if let Err(e) = DockerClient::pull_image(&svc.image).await {
                tracing::warn!(
                    "Failed to pull {}, trying with local image: {}",
                    svc.image,
                    e
                );
            }

            let mut env = HashMap::new();
            env.insert("VIBE_PROJECT_ID".to_string(), project.id.clone());

            let mut ports = Vec::new();
            if svc.container_port > 0 {
                ports.push(PortMapping {
                    host: svc.host_port,
                    container: svc.container_port,
                });
            }

            let mut labels = HashMap::new();
            labels.insert("vibe.project".to_string(), project.id.clone());
            labels.insert("vibe.service".to_string(), svc.name.clone());

            let spec = ContainerSpec {
                name: svc.container_name.clone(),
                image: svc.image.clone(),
                command: svc.command.clone(),
                env,
                ports,
                volumes: vec![VolumeMount {
                    host_path: project.extract_dir.clone(),
                    container_path: "/app".to_string(),
                }],
                working_dir: Some("/app".to_string()),
                network: Some(project.network_name.clone()),
                labels,
            };

            DockerClient::run_container(&spec).await?;
        }

        // Update status
        {
            let mut projects = self.projects.write().await;
            if let Some(p) = projects.get_mut(project_id) {
                p.status = ProjectStatus::Running;
                for svc in &mut p.services {
                    svc.running = true;
                }
            }
        }

        let projects = self.projects.read().await;
        Ok(projects.get(project_id).cloned().unwrap())
    }

    /// Stop all services for a project.
    pub async fn stop_project(
        &self,
        project_id: &str,
        timeout_secs: u32,
    ) -> Result<ManagedProject> {
        let project = {
            let projects = self.projects.read().await;
            projects
                .get(project_id)
                .cloned()
                .ok_or_else(|| ProjectError::NotFound(project_id.to_string()))?
        };

        // Update status
        {
            let mut projects = self.projects.write().await;
            if let Some(p) = projects.get_mut(project_id) {
                p.status = ProjectStatus::Stopping;
            }
        }

        // Stop and remove all containers (reverse order)
        for svc in project.services.iter().rev() {
            let _ = DockerClient::stop_container(&svc.container_name, timeout_secs).await;
            let _ = DockerClient::remove_container(&svc.container_name).await;
        }

        // Remove network
        let _ = DockerClient::remove_network(&project.network_name).await;

        // Update status
        {
            let mut projects = self.projects.write().await;
            if let Some(p) = projects.get_mut(project_id) {
                p.status = ProjectStatus::Stopped;
                for svc in &mut p.services {
                    svc.running = false;
                }
            }
        }

        let projects = self.projects.read().await;
        Ok(projects.get(project_id).cloned().unwrap())
    }

    /// Get project status (refreshes container running state).
    pub async fn get_project(&self, project_id: &str) -> Result<ManagedProject> {
        let mut projects = self.projects.write().await;
        let project = projects
            .get_mut(project_id)
            .ok_or_else(|| ProjectError::NotFound(project_id.to_string()))?;

        // Refresh running state from Docker
        let mut all_running = true;
        let mut any_running = false;
        for svc in &mut project.services {
            let running = DockerClient::is_running(&svc.container_name)
                .await
                .unwrap_or(false);
            svc.running = running;
            if running {
                any_running = true;
            } else {
                all_running = false;
            }
        }

        if !project.services.is_empty() {
            if all_running {
                project.status = ProjectStatus::Running;
            } else if any_running {
                project.status = ProjectStatus::Starting; // partial
            } else if project.status == ProjectStatus::Running {
                project.status = ProjectStatus::Error; // was running but all stopped
            }
        }

        Ok(project.clone())
    }

    /// List all managed projects.
    pub async fn list_projects(&self) -> Vec<ManagedProject> {
        self.projects.read().await.values().cloned().collect()
    }

    /// Remove a project from the manager (stops containers if running).
    pub async fn remove_project(&self, project_id: &str) -> Result<()> {
        // Stop if running
        let _ = self.stop_project(project_id, 10).await;
        self.projects.write().await.remove(project_id);
        Ok(())
    }
}

/// Extract the vibe.yaml manifest from a .vibeapp ZIP archive.
fn extract_manifest(data: &[u8]) -> Result<Manifest> {
    let reader = std::io::Cursor::new(data);
    let mut archive =
        zip::ZipArchive::new(reader).map_err(|e| ProjectError::Package(e.to_string()))?;

    // Try JSON first (_vibe_app_manifest.json), then YAML (vibe.yaml)
    if let Ok(mut entry) = archive.by_name("_vibe_app_manifest.json") {
        let mut contents = String::new();
        entry
            .read_to_string(&mut contents)
            .map_err(|e| ProjectError::Package(e.to_string()))?;
        let manifest: Manifest =
            serde_json::from_str(&contents).map_err(|e| ProjectError::Package(e.to_string()))?;
        return Ok(manifest);
    }

    if let Ok(mut entry) = archive.by_name("vibe.yaml") {
        let mut contents = String::new();
        entry
            .read_to_string(&mut contents)
            .map_err(|e| ProjectError::Package(e.to_string()))?;
        let manifest = vibe_manifest::parse::parse_manifest(&contents)
            .map_err(|e| ProjectError::Package(e.to_string()))?;
        return Ok(manifest);
    }

    Err(ProjectError::Package(
        "no manifest found in package".to_string(),
    ))
}

/// Extract all app files from a .vibeapp ZIP to a directory.
/// Skips internal metadata files (_vibe_*).
fn extract_package_files(data: &[u8], dest: &Path) -> Result<()> {
    use std::io::Read as _;

    let reader = std::io::Cursor::new(data);
    let mut archive =
        zip::ZipArchive::new(reader).map_err(|e| ProjectError::Package(e.to_string()))?;

    std::fs::create_dir_all(dest)?;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| ProjectError::Package(e.to_string()))?;
        let name = entry.name().to_string();

        // Skip metadata files
        if name.starts_with("_vibe_") {
            continue;
        }

        let out_path = dest.join(&name);

        if entry.is_dir() {
            std::fs::create_dir_all(&out_path)?;
        } else {
            if let Some(parent) = out_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let mut contents = Vec::new();
            entry
                .read_to_end(&mut contents)
                .map_err(|e| ProjectError::Package(e.to_string()))?;
            std::fs::write(&out_path, &contents)?;
        }
    }

    Ok(())
}
