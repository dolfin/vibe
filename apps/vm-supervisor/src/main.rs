mod api;
mod grpc;
mod health;
mod project;

use std::net::SocketAddr;
use std::sync::Arc;

use tonic::transport::Server;
use vibe_rpc::supervisor::supervisor_server::SupervisorServer;

use project::ProjectManager;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("Starting Vibe VM Supervisor");

    let manager = Arc::new(ProjectManager::new());

    let grpc_addr: SocketAddr = "0.0.0.0:50051".parse()?;
    let http_port: u16 = 8090;

    let supervisor = grpc::SupervisorService;
    let grpc_server = Server::builder()
        .add_service(SupervisorServer::new(supervisor))
        .serve(grpc_addr);

    tracing::info!("gRPC server listening on {}", grpc_addr);

    tokio::select! {
        result = grpc_server => {
            if let Err(e) = result {
                tracing::error!("gRPC server error: {}", e);
            }
        }
        result = health::serve(http_port, manager.clone()) => {
            if let Err(e) = result {
                tracing::error!("HTTP API server error: {}", e);
            }
        }
        _ = tokio::signal::ctrl_c() => {
            tracing::info!("Received shutdown signal, shutting down gracefully");
        }
    }

    tracing::info!("Vibe VM Supervisor shut down");
    Ok(())
}
