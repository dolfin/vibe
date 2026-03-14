use std::sync::Arc;

use axum::{routing::get, Json, Router};
use serde_json::json;

use crate::project::ProjectManager;

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({"status": "ok"}))
}

pub fn router(manager: Arc<ProjectManager>) -> Router {
    let api_routes = crate::api::router(manager);

    Router::new()
        .route("/healthz", get(healthz))
        .merge(api_routes)
}

pub async fn serve(
    port: u16,
    manager: Arc<ProjectManager>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("HTTP API server listening on {}", addr);
    axum::serve(listener, router(manager)).await?;
    Ok(())
}
