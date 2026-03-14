//! Vibe container runtime adapter.
//!
//! Wraps the Docker CLI to manage containers for Vibe applications.

use std::collections::HashMap;
use tokio::process::Command;

#[derive(Debug, thiserror::Error)]
pub enum DockerError {
    #[error("docker command failed: {0}")]
    CommandFailed(String),
    #[error("docker not found — is Docker Desktop running?")]
    NotFound,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json parse error: {0}")]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, DockerError>;

/// Describes a container to run.
#[derive(Debug, Clone)]
pub struct ContainerSpec {
    pub name: String,
    pub image: String,
    pub command: Vec<String>,
    pub env: HashMap<String, String>,
    pub ports: Vec<PortMapping>,
    pub volumes: Vec<VolumeMount>,
    pub working_dir: Option<String>,
    pub network: Option<String>,
    pub labels: HashMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct VolumeMount {
    pub host_path: String,
    pub container_path: String,
}

#[derive(Debug, Clone)]
pub struct PortMapping {
    pub host: u16,
    pub container: u16,
}

/// Status of a running container.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ContainerStatus {
    #[serde(rename = "ID")]
    pub id: String,
    #[serde(rename = "State")]
    pub state: String,
    #[serde(rename = "Status")]
    pub status: String,
}

/// Docker CLI client.
pub struct DockerClient;

impl DockerClient {
    /// Check if Docker is available and running.
    pub async fn check() -> Result<()> {
        let output = Command::new("docker")
            .args(["info", "--format", "{{.ServerVersion}}"])
            .output()
            .await
            .map_err(|_| DockerError::NotFound)?;

        if !output.status.success() {
            return Err(DockerError::NotFound);
        }
        Ok(())
    }

    /// Pull a Docker image.
    pub async fn pull_image(image: &str) -> Result<()> {
        tracing::info!("Pulling image: {}", image);
        let output = Command::new("docker")
            .args(["pull", image])
            .output()
            .await?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(DockerError::CommandFailed(format!(
                "docker pull {} failed: {}",
                image, stderr
            )));
        }
        Ok(())
    }

    /// Create and start a container from a spec.
    pub async fn run_container(spec: &ContainerSpec) -> Result<String> {
        // Remove any existing container with the same name
        let _ = Self::remove_container(&spec.name).await;

        let mut args = vec!["run".to_string(), "-d".to_string()];
        args.push("--name".to_string());
        args.push(spec.name.clone());

        for pm in &spec.ports {
            args.push("-p".to_string());
            args.push(format!("{}:{}", pm.host, pm.container));
        }

        for (k, v) in &spec.env {
            args.push("-e".to_string());
            args.push(format!("{}={}", k, v));
        }

        if let Some(net) = &spec.network {
            args.push("--network".to_string());
            args.push(net.clone());
        }

        for vol in &spec.volumes {
            args.push("-v".to_string());
            args.push(format!("{}:{}", vol.host_path, vol.container_path));
        }

        if let Some(wd) = &spec.working_dir {
            args.push("-w".to_string());
            args.push(wd.clone());
        }

        for (k, v) in &spec.labels {
            args.push("--label".to_string());
            args.push(format!("{}={}", k, v));
        }

        args.push(spec.image.clone());
        args.extend(spec.command.clone());

        tracing::info!("Running container: {}", spec.name);
        let output = Command::new("docker").args(&args).output().await?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(DockerError::CommandFailed(format!(
                "docker run {} failed: {}",
                spec.name, stderr
            )));
        }

        let container_id = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Ok(container_id)
    }

    /// Stop a container by name.
    pub async fn stop_container(name: &str, timeout_secs: u32) -> Result<()> {
        tracing::info!("Stopping container: {}", name);
        let output = Command::new("docker")
            .args(["stop", "-t", &timeout_secs.to_string(), name])
            .output()
            .await?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(DockerError::CommandFailed(format!(
                "docker stop {} failed: {}",
                name, stderr
            )));
        }
        Ok(())
    }

    /// Remove a container by name (force).
    pub async fn remove_container(name: &str) -> Result<()> {
        let output = Command::new("docker")
            .args(["rm", "-f", name])
            .output()
            .await?;

        if !output.status.success() {
            // Ignore "no such container" errors
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !stderr.contains("No such container") {
                return Err(DockerError::CommandFailed(format!(
                    "docker rm {} failed: {}",
                    name, stderr
                )));
            }
        }
        Ok(())
    }

    /// Check if a container is running.
    pub async fn is_running(name: &str) -> Result<bool> {
        let output = Command::new("docker")
            .args(["inspect", "--format", "{{.State.Running}}", name])
            .output()
            .await?;

        if !output.status.success() {
            return Ok(false);
        }

        let running = String::from_utf8_lossy(&output.stdout)
            .trim()
            .eq_ignore_ascii_case("true");
        Ok(running)
    }

    /// Create a Docker network (ignores "already exists" errors).
    pub async fn create_network(name: &str) -> Result<()> {
        let output = Command::new("docker")
            .args(["network", "create", name])
            .output()
            .await?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !stderr.contains("already exists") {
                return Err(DockerError::CommandFailed(format!(
                    "docker network create {} failed: {}",
                    name, stderr
                )));
            }
        }
        Ok(())
    }

    /// Remove a Docker network.
    pub async fn remove_network(name: &str) -> Result<()> {
        let _ = Command::new("docker")
            .args(["network", "rm", name])
            .output()
            .await?;
        Ok(())
    }

    /// Find an available host port starting from a preferred port.
    /// Checks both OS-level and Docker-level port usage.
    pub async fn find_available_port(preferred: u16) -> u16 {
        let docker_ports = Self::docker_used_ports().await;

        for port in preferred..preferred + 100 {
            // Skip ports Docker is already using
            if docker_ports.contains(&port) {
                continue;
            }
            // Check both 0.0.0.0 and 127.0.0.1 (Docker binds to 0.0.0.0)
            let bind_all = tokio::net::TcpListener::bind(("0.0.0.0", port)).await;
            let bind_lo = tokio::net::TcpListener::bind(("127.0.0.1", port)).await;
            if bind_all.is_ok() && bind_lo.is_ok() {
                return port;
            }
        }
        // Fallback: let OS pick an ephemeral port
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0u16))
            .await
            .expect("OS should assign an ephemeral port");
        listener.local_addr().unwrap().port()
    }

    /// Query Docker for all host ports currently in use.
    async fn docker_used_ports() -> std::collections::HashSet<u16> {
        let mut ports = std::collections::HashSet::new();
        let output = Command::new("docker")
            .args(["ps", "--format", "{{.Ports}}"])
            .output()
            .await;

        if let Ok(output) = output {
            let text = String::from_utf8_lossy(&output.stdout);
            // Parse lines like "0.0.0.0:3000->3000/tcp, :::3000->3000/tcp"
            for segment in text.split([',', '\n']) {
                let segment = segment.trim();
                // Look for "host:port->" pattern
                if let Some(arrow) = segment.find("->") {
                    let before_arrow = &segment[..arrow];
                    if let Some(colon) = before_arrow.rfind(':') {
                        if let Ok(port) = before_arrow[colon + 1..].parse::<u16>() {
                            ports.insert(port);
                        }
                    }
                }
            }
        }
        ports
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_find_available_port() {
        let port = DockerClient::find_available_port(18080).await;
        assert!(port >= 18080);
    }
}
