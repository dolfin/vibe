use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

use vibe_rpc::supervisor::supervisor_server::Supervisor;
use vibe_rpc::supervisor::*;

pub struct SupervisorService;

#[tonic::async_trait]
impl Supervisor for SupervisorService {
    async fn ensure_project(
        &self,
        _request: Request<EnsureProjectRequest>,
    ) -> Result<Response<EnsureProjectResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn open_project(
        &self,
        _request: Request<OpenProjectRequest>,
    ) -> Result<Response<OpenProjectResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn start_project(
        &self,
        _request: Request<StartProjectRequest>,
    ) -> Result<Response<StartProjectResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn stop_project(
        &self,
        _request: Request<StopProjectRequest>,
    ) -> Result<Response<StopProjectResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn delete_project_runtime(
        &self,
        _request: Request<DeleteProjectRuntimeRequest>,
    ) -> Result<Response<DeleteProjectRuntimeResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn list_projects(
        &self,
        _request: Request<ListProjectsRequest>,
    ) -> Result<Response<ListProjectsResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn get_project_status(
        &self,
        _request: Request<GetProjectStatusRequest>,
    ) -> Result<Response<GetProjectStatusResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    type GetProjectLogsStream = ReceiverStream<Result<LogEntry, Status>>;

    async fn get_project_logs(
        &self,
        _request: Request<GetProjectLogsRequest>,
    ) -> Result<Response<Self::GetProjectLogsStream>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn save_snapshot(
        &self,
        _request: Request<SaveSnapshotRequest>,
    ) -> Result<Response<SaveSnapshotResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn restore_snapshot(
        &self,
        _request: Request<RestoreSnapshotRequest>,
    ) -> Result<Response<RestoreSnapshotResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn list_snapshots(
        &self,
        _request: Request<ListSnapshotsRequest>,
    ) -> Result<Response<ListSnapshotsResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn duplicate_project(
        &self,
        _request: Request<DuplicateProjectRequest>,
    ) -> Result<Response<DuplicateProjectResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn import_package(
        &self,
        _request: Request<ImportPackageRequest>,
    ) -> Result<Response<ImportPackageResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn validate_compose(
        &self,
        _request: Request<ValidateComposeRequest>,
    ) -> Result<Response<ValidateComposeResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }

    async fn resolve_ports(
        &self,
        _request: Request<ResolvePortsRequest>,
    ) -> Result<Response<ResolvePortsResponse>, Status> {
        Err(Status::unimplemented("not yet implemented"))
    }
}
