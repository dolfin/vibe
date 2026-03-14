# Compose Compatibility v1

Version: v1

## Field Support Matrix

### Supported (direct mapping)

These Compose fields map directly to the Vibe native runtime model.

| Compose Field | Notes |
|---|---|
| `services.<name>.image` | Required. Used as OCI image reference |
| `services.<name>.command` | Maps to container command override |
| `services.<name>.entrypoint` | Maps to container entrypoint |
| `services.<name>.environment` | Maps to service env vars |
| `services.<name>.env_file` | Resolved at import time, merged into env |
| `services.<name>.ports` | Short and long syntax. Mapped to port exposure model |
| `services.<name>.volumes` (named) | Named volumes map to state volumes |
| `services.<name>.working_dir` | Maps to container working directory |
| `services.<name>.user` | Maps to container user |
| `services.<name>.restart` | Mapped to restart policy |
| `services.<name>.healthcheck` | Maps to health check configuration |
| `services.<name>.labels` | Preserved as service labels |
| `volumes` (top-level named) | Created as project-scoped named volumes |

### Supported with Transformation

These fields are accepted but require rewriting during import.

| Compose Field | Transformation |
|---|---|
| `services.<name>.build` | Rejected at runtime. Optional offline prebuild/import flow: developer must build the image externally and provide it as a registry reference. Import report flags this |
| `services.<name>.volumes` (bind mounts) | Relative host paths are remapped into the imported workspace under `state/current/files/`. Absolute host paths are rejected |
| `services.<name>.depends_on` | Simple form maps to startup ordering. Extended form (`condition: service_healthy`) maps to startup ordering + health check gate |
| `services.<name>.networks` | Custom networks are collapsed into the single project network. Service aliases are preserved for DNS resolution |
| `services.<name>.expose` | Treated as internal-only port declaration (no host exposure) |
| `services.<name>.tmpfs` | Mapped to in-memory tmpfs mount inside the container |
| `services.<name>.logging` | Driver-specific options are dropped. Logs are captured by the supervisor's unified log collector |

### Rejected

These fields are not supported in v1. Their presence triggers a warning in the import report but does not block import unless marked critical.

| Compose Field | Reason |
|---|---|
| `services.<name>.privileged` | No privileged containers in v1 |
| `services.<name>.cap_add` | Capabilities are dropped by default; adding is not permitted in v1 |
| `services.<name>.pid` | No host PID namespace sharing |
| `services.<name>.network_mode: host` | No host network mode in VM context |
| `services.<name>.devices` | No device passthrough in v1 |
| `services.<name>.sysctls` | No sysctl modification in v1 |
| `services.<name>.security_opt` | Managed by runtime hardening, not user-configurable |
| `services.<name>.deploy` | Swarm/orchestration directives are ignored |
| `services.<name>.configs` | Docker configs not supported; use env vars or mounted files |
| `services.<name>.secrets` (Docker secrets) | Use Vibe secret model (Keychain or encrypted package) instead |
| `services.<name>.extends` | Service inheritance not supported |
| `services.<name>.profiles` | Profile-based service activation not supported |
| `networks` (top-level custom) | Custom network topologies are collapsed; complex driver options rejected |

## Import Pipeline

The Compose import executes these 7 steps:

1. **Locate Compose file** --- resolve the path from `runtime.composeFile` in the manifest. Support `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`

2. **Parse and validate** --- parse YAML, validate against Compose specification structure. Reject files that are not valid Compose syntax

3. **Normalize service definitions** --- expand short-form syntax (ports, volumes, environment) into canonical long form. Resolve `env_file` references and merge into environment maps

4. **Reject unsupported fields** --- scan every service for fields in the "rejected" bucket. Collect all rejections into the import report. Rejections are warnings by default, not hard failures

5. **Rewrite host-path assumptions to VM-local paths** --- all relative bind mounts are remapped to `state/current/files/<import-dir>/`. Absolute host paths are rejected. Build contexts are flagged for prebuild

6. **Map services to internal runtime model** --- convert each Compose service into the native Vibe service definition: image, command, env, ports, mounts, volumes, dependsOn, healthcheck

7. **Generate import report** --- produce a structured report listing:
   - Services imported successfully
   - Fields that were transformed (with explanation)
   - Fields that were rejected (with reason)
   - Warnings and recommendations
   - Whether the app is expected to function correctly

## Common Transformations

### `build`

Compose `build` directives cannot be executed at runtime. The import pipeline:
- Flags the service in the import report
- Requires the developer to prebuild the image and push it to a registry
- The developer must replace `build` with an `image` reference before the app will run

### Relative Bind Mounts

```yaml
# Compose input
volumes:
  - ./data:/app/data

# Transformed to
mounts:
  - source: state:imported-data
    target: /app/data
```

The contents of `./data` from the Compose project directory are copied into `state/current/files/imported-data/` at import time.

### `depends_on`

```yaml
# Simple form
depends_on:
  - db

# Extended form
depends_on:
  db:
    condition: service_healthy
```

Both forms map to the `dependsOn` array. The extended form additionally gates startup on the dependency's health check passing.

## nerdctl Compose Usage

`nerdctl compose` is used only as:
- **Validation oracle** --- during development, to verify that the Compose file is structurally valid
- **Debug path** --- as an optional fallback for developer debugging workflows
- **Not a production dependency** --- project lifecycle never shells out to `nerdctl compose` in normal operation

All production Compose handling goes through the import pipeline above, producing native runtime plans executed by the supervisor.
