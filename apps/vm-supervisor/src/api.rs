//! REST API for the Swift host app to manage projects.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{delete, get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::project::{ManagedProject, ProjectManager};

/// API response wrapper.
#[derive(Serialize)]
struct ApiResponse<T: Serialize> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl<T: Serialize> ApiResponse<T> {
    fn success(data: T) -> Json<ApiResponse<T>> {
        Json(ApiResponse {
            ok: true,
            data: Some(data),
            error: None,
        })
    }
}

fn error_response<T: Serialize>(
    status: StatusCode,
    msg: &str,
) -> (StatusCode, Json<ApiResponse<T>>) {
    (
        status,
        Json(ApiResponse {
            ok: false,
            data: None,
            error: Some(msg.to_string()),
        }),
    )
}

#[derive(Deserialize)]
pub struct ImportRequest {
    pub package_path: String,
}

#[derive(Deserialize)]
pub struct StopRequest {
    #[serde(default = "default_timeout")]
    pub timeout_seconds: u32,
}

fn default_timeout() -> u32 {
    10
}

/// Build the REST API router.
pub fn router(manager: Arc<ProjectManager>) -> Router {
    Router::new()
        .route("/api/projects", get(list_projects))
        .route("/api/projects/import", post(import_project))
        .route("/api/projects/:project_id", get(get_project))
        .route("/api/projects/:project_id", delete(remove_project))
        .route("/api/projects/:project_id/start", post(start_project))
        .route("/api/projects/:project_id/stop", post(stop_project))
        .with_state(manager)
}

async fn list_projects(
    State(manager): State<Arc<ProjectManager>>,
) -> Json<ApiResponse<Vec<ManagedProject>>> {
    let projects = manager.list_projects().await;
    ApiResponse::success(projects)
}

async fn import_project(
    State(manager): State<Arc<ProjectManager>>,
    Json(req): Json<ImportRequest>,
) -> std::result::Result<
    Json<ApiResponse<ManagedProject>>,
    (StatusCode, Json<ApiResponse<ManagedProject>>),
> {
    let path = std::path::Path::new(&req.package_path);
    match manager.import_package(path).await {
        Ok(project) => Ok(ApiResponse::success(project)),
        Err(e) => Err(error_response(StatusCode::BAD_REQUEST, &e.to_string())),
    }
}

async fn get_project(
    State(manager): State<Arc<ProjectManager>>,
    Path(project_id): Path<String>,
) -> std::result::Result<
    Json<ApiResponse<ManagedProject>>,
    (StatusCode, Json<ApiResponse<ManagedProject>>),
> {
    match manager.get_project(&project_id).await {
        Ok(project) => Ok(ApiResponse::success(project)),
        Err(e) => Err(error_response(StatusCode::NOT_FOUND, &e.to_string())),
    }
}

async fn start_project(
    State(manager): State<Arc<ProjectManager>>,
    Path(project_id): Path<String>,
) -> std::result::Result<
    Json<ApiResponse<ManagedProject>>,
    (StatusCode, Json<ApiResponse<ManagedProject>>),
> {
    match manager.start_project(&project_id).await {
        Ok(project) => Ok(ApiResponse::success(project)),
        Err(e) => Err(error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            &e.to_string(),
        )),
    }
}

async fn stop_project(
    State(manager): State<Arc<ProjectManager>>,
    Path(project_id): Path<String>,
    Json(req): Json<StopRequest>,
) -> std::result::Result<
    Json<ApiResponse<ManagedProject>>,
    (StatusCode, Json<ApiResponse<ManagedProject>>),
> {
    match manager.stop_project(&project_id, req.timeout_seconds).await {
        Ok(project) => Ok(ApiResponse::success(project)),
        Err(e) => Err(error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            &e.to_string(),
        )),
    }
}

async fn remove_project(
    State(manager): State<Arc<ProjectManager>>,
    Path(project_id): Path<String>,
) -> std::result::Result<Json<ApiResponse<()>>, (StatusCode, Json<ApiResponse<()>>)> {
    match manager.remove_project(&project_id).await {
        Ok(()) => Ok(ApiResponse::success(())),
        Err(e) => Err(error_response(StatusCode::NOT_FOUND, &e.to_string())),
    }
}
