# RPC API v1

Version: v1
Transport: protobuf over vsock

All RPCs are between the macOS host app and the VM supervisor daemon.

---

## 1. EnsureProject

Register a project in the supervisor's registry. Idempotent --- if the project already exists, returns the existing record.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Unique project instance ID |
| `app_id` | string | App identifier from manifest |
| `package_path` | string | Path to immutable package in VM filesystem |
| `state_path` | string | Path to mutable state directory in VM filesystem |
| `manifest` | bytes | Serialized manifest content |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Confirmed project ID |
| `namespace` | string | Assigned containerd namespace |
| `created` | bool | `true` if newly created, `false` if already existed |

**Errors:**
- `INVALID_MANIFEST` --- manifest fails validation
- `PATH_NOT_FOUND` --- package or state path does not exist in VM
- `CONFLICT` --- project_id exists with different app_id

---

## 2. OpenProject

Load a project into memory, pull required images, prepare runtime plan. Does not start services.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Project to open |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Confirmed project ID |
| `services` | ServiceInfo[] | List of resolved services |
| `images_pulled` | int32 | Number of images pulled |
| `warnings` | string[] | Non-fatal warnings (e.g., image tag resolution) |

**Errors:**
- `NOT_FOUND` --- project not registered
- `IMAGE_PULL_FAILED` --- one or more images could not be fetched
- `ALREADY_OPEN` --- project already loaded

---

## 3. StartProject

Start all services for an opened project in dependency order.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Project to start |
| `secrets` | map<string, string> | Injected secrets (env var name to value) |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Confirmed project ID |
| `services` | ServiceStatus[] | Status of each started service |
| `ports` | PortMapping[] | Assigned host port mappings |

**Errors:**
- `NOT_FOUND` --- project not registered
- `NOT_OPEN` --- project not yet opened
- `ALREADY_RUNNING` --- project services already started
- `START_FAILED` --- one or more services failed to start
- `MISSING_SECRET` --- a required secret was not provided

---

## 4. StopProject

Stop all services for a running project. Graceful shutdown with configurable timeout.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Project to stop |
| `timeout_seconds` | int32 | Graceful shutdown timeout (default: 30) |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Confirmed project ID |
| `services` | ServiceStatus[] | Final status of each service |

**Errors:**
- `NOT_FOUND` --- project not registered
- `NOT_RUNNING` --- project is not currently running

---

## 5. DeleteProjectRuntime

Remove all runtime resources for a project (containers, networks, namespace). Does not delete state or snapshots.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Project to delete |
| `force` | bool | Force delete even if services are running |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Confirmed project ID |
| `resources_removed` | int32 | Count of resources cleaned up |

**Errors:**
- `NOT_FOUND` --- project not registered
- `STILL_RUNNING` --- services are running and `force` is false

---

## 6. ListProjects

List all registered projects.

**Request:**
| Field | Type | Description |
|---|---|---|
| `filter_status` | string | Optional. Filter by status (`running`, `stopped`, etc.) |

**Response:**
| Field | Type | Description |
|---|---|---|
| `projects` | ProjectSummary[] | List of project summaries |

`ProjectSummary`: `project_id`, `app_id`, `name`, `status`, `service_count`, `port_count`

**Errors:** None expected.

---

## 7. GetProjectStatus

Get detailed status for a single project.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Target project |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Project ID |
| `app_id` | string | App identifier |
| `name` | string | App display name |
| `version` | string | App version |
| `status` | string | Project-level status |
| `services` | ServiceStatus[] | Per-service status |
| `ports` | PortMapping[] | Active port mappings |
| `state_size_bytes` | int64 | Current state size |
| `snapshot_count` | int32 | Number of snapshots |
| `autosave_enabled` | bool | Whether autosave is on |

**Errors:**
- `NOT_FOUND` --- project not registered

---

## 8. GetProjectLogs

Stream or fetch logs for a project's services.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Target project |
| `service_name` | string | Optional. Filter to specific service |
| `follow` | bool | Stream new log lines as they arrive |
| `tail_lines` | int32 | Number of historical lines to return (default: 100) |

**Response (stream):**
| Field | Type | Description |
|---|---|---|
| `entries` | LogEntry[] | Log entries |

`LogEntry`: `timestamp`, `service_name`, `stream` (stdout/stderr), `line`

**Errors:**
- `NOT_FOUND` --- project or service not found

---

## 9. SaveSnapshot

Create a snapshot of the current project state.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Target project |
| `reason` | string | `manual`, `autosave`, `before-upgrade`, `before-restore` |
| `labels` | map<string, string> | Optional user labels |

**Response:**
| Field | Type | Description |
|---|---|---|
| `snapshot_id` | string | ID of created snapshot |
| `timestamp` | string | ISO 8601 timestamp |
| `state_digest` | string | SHA-256 digest of snapshot state |
| `size_bytes` | int64 | Total snapshot size |

**Errors:**
- `NOT_FOUND` --- project not registered
- `SAVE_IN_PROGRESS` --- another save is already running
- `SAVE_FAILED` --- snapshot creation failed (partial save is cleaned up)

---

## 10. RestoreSnapshot

Restore project state from a previous snapshot.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Target project |
| `snapshot_id` | string | Snapshot to restore |
| `create_safety_snapshot` | bool | Take a snapshot of current state before restoring (default: true) |

**Response:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Project ID |
| `restored_snapshot_id` | string | ID of snapshot that was restored |
| `safety_snapshot_id` | string | ID of pre-restore safety snapshot (empty if skipped) |
| `services` | ServiceStatus[] | Status after restart |

**Errors:**
- `NOT_FOUND` --- project or snapshot not found
- `SNAPSHOT_MISMATCH` --- snapshot does not belong to this project
- `RESTORE_FAILED` --- restore failed; current state is unchanged

---

## 11. ListSnapshots

List all snapshots for a project.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Target project |

**Response:**
| Field | Type | Description |
|---|---|---|
| `snapshots` | SnapshotSummary[] | List of snapshots, newest first |

`SnapshotSummary`: `snapshot_id`, `timestamp`, `parent_snapshot_id`, `reason`, `app_version`, `state_digest`, `size_bytes`, `labels`

**Errors:**
- `NOT_FOUND` --- project not registered

---

## 12. DuplicateProject

Create a new project instance by cloning state from an existing project.

**Request:**
| Field | Type | Description |
|---|---|---|
| `source_project_id` | string | Project to clone from |
| `new_project_id` | string | ID for the new project (generated if empty) |
| `snapshot_id` | string | Optional. Clone from specific snapshot instead of current state |

**Response:**
| Field | Type | Description |
|---|---|---|
| `new_project_id` | string | ID of the created project |
| `namespace` | string | Assigned containerd namespace |
| `state_path` | string | Path to new project's state |

**Errors:**
- `NOT_FOUND` --- source project or snapshot not found
- `DUPLICATE_FAILED` --- clone operation failed

---

## 13. ImportPackage

Import a `.vibeapp` package into the VM and register it.

**Request:**
| Field | Type | Description |
|---|---|---|
| `package_data_path` | string | Path to package file in VM filesystem |
| `verify_signature` | bool | Whether to verify package signature |

**Response:**
| Field | Type | Description |
|---|---|---|
| `app_id` | string | App identifier from manifest |
| `name` | string | App display name |
| `version` | string | App version |
| `trust_status` | string | `signed_trusted`, `signed_untrusted`, `unsigned`, `tampered` |
| `package_path` | string | Path to extracted package in VM |
| `capabilities` | string[] | Requested capabilities (network, hostFileImport, etc.) |

**Errors:**
- `PATH_NOT_FOUND` --- package file does not exist
- `INVALID_PACKAGE` --- package structure is invalid
- `SIGNATURE_INVALID` --- signature verification failed
- `TAMPERED` --- package contents do not match manifest digests

---

## 14. ValidateCompose

Validate a Compose file against the supported subset and return an import report.

**Request:**
| Field | Type | Description |
|---|---|---|
| `compose_content` | bytes | Raw Compose file content |

**Response:**
| Field | Type | Description |
|---|---|---|
| `valid` | bool | Whether the file can be imported |
| `services` | ComposeServiceReport[] | Per-service analysis |
| `supported_fields` | string[] | Fields that map directly |
| `transformed_fields` | TransformReport[] | Fields supported with transformation |
| `rejected_fields` | RejectedField[] | Unsupported fields |
| `warnings` | string[] | Non-fatal warnings |

**Errors:**
- `PARSE_ERROR` --- Compose file is not valid YAML
- `INVALID_COMPOSE` --- file is valid YAML but not a valid Compose file

---

## 15. ResolvePorts

Query or refresh host port allocations for a project.

**Request:**
| Field | Type | Description |
|---|---|---|
| `project_id` | string | Target project |
| `refresh` | bool | Re-allocate ports if current mappings are stale |

**Response:**
| Field | Type | Description |
|---|---|---|
| `ports` | PortMapping[] | Current port mappings |

`PortMapping`: `service_name`, `container_port`, `host_port`, `protocol`

**Errors:**
- `NOT_FOUND` --- project not registered
- `NOT_RUNNING` --- project has no active port mappings
- `PORT_CONFLICT` --- unable to allocate non-conflicting host ports

---

## Common Types

### ServiceStatus
| Field | Type |
|---|---|
| `name` | string |
| `status` | string (`stopped`, `starting`, `running`, `stopping`, `failed`) |
| `container_id` | string |
| `started_at` | string (ISO 8601) |
| `restart_count` | int32 |

### PortMapping
| Field | Type |
|---|---|
| `service_name` | string |
| `container_port` | int32 |
| `host_port` | int32 |
| `protocol` | string (`tcp`, `udp`) |
