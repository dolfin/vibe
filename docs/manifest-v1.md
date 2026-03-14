# Manifest v1 Specification

Version: v1
Kind: `vibe.app/v1`

## Complete Example

```yaml
kind: vibe.app/v1
id: com.example.todo
name: Todo App
version: 1.0.0
icon: assets/icon.png

runtime:
  mode: native # native | compose
  composeFile: compose.yaml

services:
  - name: web
    image: ghcr.io/example/todo-web:1.0.0
    command: ["node", "server.js"]
    env:
      NODE_ENV: production
    ports:
      - container: 3000
        hostExposure: auto
    mounts:
      - source: state:uploads
        target: /data/uploads
    dependsOn: ["db"]

  - name: db
    image: postgres:16
    env:
      POSTGRES_DB: todo
      POSTGRES_USER: todo
    stateVolumes:
      - dbdata:/var/lib/postgresql/data

state:
  autosave: true
  autosaveDebounceSeconds: 30
  retention:
    maxSnapshots: 100
  volumes:
    - name: dbdata
      consistency: postgres
    - name: uploads
      consistency: generic

security:
  network: true
  allowHostFileImport: true

secrets:
  - name: OPENAI_API_KEY
    required: true
  - name: AWS_SECRET_ACCESS_KEY
    required: false

publisher:
  name: Example Inc.
  signing:
    scheme: ed25519
    signatureFile: signatures/package.sig
    publicKeyFile: signatures/publisher.pub
```

## Field Reference

### Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | **required** | Must be `vibe.app/v1` |
| `id` | string | **required** | Reverse-domain app identifier (e.g., `com.example.todo`) |
| `name` | string | **required** | Human-readable app name |
| `version` | string | **required** | Semver version string |
| `icon` | string | optional | Relative path to icon asset within the package |

### `runtime`

| Field | Type | Required | Description |
|---|---|---|---|
| `mode` | enum | **required** | `native` or `compose` |
| `composeFile` | string | conditional | Relative path to Compose file. Required when `mode: compose`, ignored when `mode: native` |

**Validation:**
- When `mode: native`, services must be defined inline under `services`
- When `mode: compose`, `composeFile` must point to a valid file within the package

### `services[]`

Each entry in the services array defines one container.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | **required** | Unique service name within the app |
| `image` | string | **required** | OCI image reference (registry/repo:tag or digest) |
| `command` | string[] | optional | Override container entrypoint |
| `env` | map[string]string | optional | Environment variables |
| `ports` | port[] | optional | Port exposure definitions |
| `mounts` | mount[] | optional | Bind-style mounts from state area |
| `stateVolumes` | string[] | optional | Named volume mounts (`name:/path`) |
| `dependsOn` | string[] | optional | Service names that must start before this service |

#### `services[].ports[]`

| Field | Type | Required | Description |
|---|---|---|---|
| `container` | int | **required** | Container port number (1-65535) |
| `hostExposure` | enum | optional | `auto` (default) --- system assigns host port. `none` --- no host exposure |

#### `services[].mounts[]`

| Field | Type | Required | Description |
|---|---|---|---|
| `source` | string | **required** | Mount source. Format: `state:<volume-name>` for state-backed mounts |
| `target` | string | **required** | Absolute path inside the container |

### `state`

| Field | Type | Required | Description |
|---|---|---|---|
| `autosave` | bool | optional | Enable autosave snapshots. Default: `false` |
| `autosaveDebounceSeconds` | int | optional | Minimum seconds between autosaves. Default: `30` |
| `retention` | object | optional | Snapshot retention policy |
| `retention.maxSnapshots` | int | optional | Maximum snapshots to retain. Default: `100` |
| `volumes` | volume[] | optional | Volume definitions with consistency policies |

#### `state.volumes[]`

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | **required** | Volume name, referenced by services |
| `consistency` | enum | **required** | `sqlite`, `postgres`, or `generic` |

**Consistency enum values:**
- `sqlite` --- WAL checkpoint + fsync before snapshot
- `postgres` --- logical dump for portable snapshots
- `generic` --- best-effort copy (pause + tar)

### `security`

| Field | Type | Required | Description |
|---|---|---|---|
| `network` | bool | optional | App requests outbound network access. Default: `false` |
| `allowHostFileImport` | bool | optional | App requests ability to import files from host. Default: `false` |

### `secrets[]`

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | **required** | Secret name (used as env var name at injection) |
| `required` | bool | optional | Whether the app refuses to start without this secret. Default: `false` |

### `publisher`

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | **required** | Publisher display name |
| `signing` | object | optional | Package signing configuration |
| `signing.scheme` | enum | **required** (if signing present) | `ed25519` |
| `signing.signatureFile` | string | **required** (if signing present) | Relative path to detached signature |
| `signing.publicKeyFile` | string | **required** (if signing present) | Relative path to publisher public key |

## Validation Rules

1. `kind` must be exactly `vibe.app/v1`
2. `id` must match pattern `^[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*)+$`
3. `version` must be valid semver
4. All relative paths must not contain `..` (path traversal rejected)
5. Service names must be unique within the manifest
6. Volume names referenced in `stateVolumes` or `mounts` must have a corresponding entry in `state.volumes`
7. `dependsOn` references must point to service names defined in the same manifest
8. Container ports must be in range 1-65535
9. When `mode: compose`, the `services` array is ignored (services come from the Compose file)
10. When `mode: native`, `composeFile` is ignored
