---
name: vibe
description: Vibe app development — use when writing or editing vibe.yaml manifests, packaging .vibeapp files, or using the Vibe CLI. Covers manifest schema, validation rules, and the full packaging workflow.
user-invocable: true
---

# Vibe App Development

Vibe apps are defined as `vibe.yaml` manifests, packaged into signed `.vibeapp` archives,
and run inside a persistent Alpine Linux VM on macOS via the Vibe runtime.

## Minimal vibe.yaml

```yaml
kind: vibe.app/v1          # required, exact string
id: com.example.myapp      # reverse-DNS, at least two segments
name: My App
version: 1.0.0             # semver

services:
  - name: web
    image: node:20-alpine
    command: ["node", "server.js"]
    ports:
      - container: 3000    # port exposed inside the VM
```

## Multi-service vibe.yaml

```yaml
kind: vibe.app/v1
id: com.example.todo
name: Todo App
version: 1.0.0

services:
  - name: web
    image: node:20-alpine
    command: ["node", "server.js"]
    ports:
      - container: 3000
    dependOn: ["db"]        # NOTE: dependOn, NOT dependsOn
    env:
      DATABASE_URL: "postgres://postgres:password@localhost:5432/todo"
      NODE_ENV: "production"

  - name: db
    image: postgres:16
    env:
      POSTGRES_PASSWORD: "password"
      POSTGRES_DB: "todo"
    mounts:
      - volume: pgdata       # must be declared in state.volumes
        path: /var/lib/postgresql/data

state:
  volumes:
    - name: pgdata
      consistency: postgres  # postgres | sqlite | generic

security:
  network: true
  allowHostFileImport: false

secrets:
  - name: API_KEY
    required: true

publisher:
  name: Example Corp
```

## Field Reference

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `kind` | string | yes | Must be exactly `vibe.app/v1` |
| `id` | string | yes | Reverse-DNS, e.g. `com.example.app` |
| `name` | string | yes | Human-readable display name |
| `version` | string | yes | Semver, e.g. `1.0.0` |
| `services` | array | yes | At least one service required |
| `services[].name` | string | yes | Unique within manifest |
| `services[].image` | string | yes | Docker image reference |
| `services[].command` | array | no | Override container entrypoint |
| `services[].ports` | array | no | Ports to expose |
| `services[].dependOn` | array | no | Service names this service depends on |
| `services[].env` | map | no | Environment variables (uppercase keys) |
| `services[].mounts` | array | no | Volume mounts (volume must be in `state.volumes`) |
| `state.volumes` | array | no | Named persistent volumes |
| `state.volumes[].consistency` | string | no | `generic` \| `sqlite` \| `postgres` |
| `security.network` | bool | no | Allow network access (default: true) |
| `security.allowHostFileImport` | bool | no | Allow importing host files (default: false) |
| `secrets` | array | no | Named secrets injected as env vars |
| `ui` | object | no | Browser chrome options |
| `publisher.name` | string | no | Publisher display name |

## Validation Rules

1. `kind` must be exactly `vibe.app/v1`
2. `id` must match `^[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*)+$` (reverse-DNS, 2+ segments)
3. `version` must be valid semver (e.g. `1.0.0`)
4. No `..` in any path value (path traversal prevention)
5. `dependOn` names must reference services defined in the same manifest
6. No circular dependencies between services
7. Volume names in `mounts` must be declared in `state.volumes`
8. State volume `consistency`: `generic` | `sqlite` | `postgres`
9. Env var names must match `^[A-Z_][A-Z0-9_]*$` (uppercase only)
10. Container ports must be 1–65535; max 20 services per manifest

## CLI Workflow

```bash
vibe validate vibe.yaml          # check manifest for errors
vibe package vibe.yaml -o app.vibeapp   # create archive
vibe keygen -o signing           # one-time: generate signing.key + signing.pub
vibe sign app.vibeapp --key signing.key # sign the package
vibe verify app.vibeapp --key signing.pub  # verify signature
vibe inspect app.vibeapp         # show manifest + file listing
vibe revert app.vibeapp          # strip saved state, restore original
```

## Password Protection

All commands that read or write `.vibeapp` files accept these flags:

```
--password <pass>        Use directly (avoid: visible in shell history)
--password-file <path>   Read password from file (suitable for CI)
(neither)                Interactive prompt — most secure, not logged
```

```bash
# Create a password-protected package
vibe package vibe.yaml -o app.vibeapp --password hunter2

# Inspect / verify / sign / revert an encrypted package
vibe inspect app.vibeapp --password hunter2
vibe verify  app.vibeapp --key signing.pub --password hunter2
vibe sign    app.vibeapp --key signing.key --password hunter2
vibe revert  app.vibeapp --password hunter2

# Omit the flag to be prompted interactively
vibe inspect app.vibeapp
```

- Unencrypted packages: `--password` is silently ignored.
- Wrong password: command fails with `"Wrong password or corrupted package"`.
- The host app detects encryption automatically and shows a password dialog.

## Packaging Workflow (step-by-step)

1. Check `vibe.yaml` exists; if not, run `vibe init <name>` first
2. Run `vibe validate vibe.yaml` — fix all errors before proceeding
3. Derive output filename from `id` last segment (e.g. `com.example.todo` → `todo.vibeapp`)
4. Run `vibe package vibe.yaml -o <name>.vibeapp` (add `--password` to encrypt)
5. If `signing.key` exists → run `vibe sign <name>.vibeapp --key signing.key`
6. Run `vibe inspect <name>.vibeapp` — confirm contents
7. If no signing key, remind: run `vibe keygen -o signing` to generate one

## Common Mistakes

- Missing `kind: vibe.app/v1` (required, exact string)
- `id` with only one segment (e.g. `myapp` instead of `com.example.myapp`)
- Referencing a volume in `mounts` without declaring it in `state.volumes`
- Lowercase env var names in `env:` map (must be `UPPER_CASE`)
- Using `dependsOn` instead of `dependOn`
- Using `depends_on` (Docker Compose style) instead of `dependOn`
- Forgetting semver format for `version` (e.g. writing `1.0` instead of `1.0.0`)

Full schema reference: `docs/manifest-v1.md`
