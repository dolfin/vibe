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
vibe init <name>                 # scaffold new project → creates <name>/vibe.yaml + <name>/.vibeignore
vibe validate vibe.yaml          # check manifest for errors
vibe package vibe.yaml -o app.vibeapp   # create archive
vibe keygen -o signing           # one-time: generate signing.key + signing.pub
vibe sign app.vibeapp --key signing.key # sign the package
vibe verify app.vibeapp --key signing.pub  # verify signature
vibe inspect app.vibeapp         # show manifest + file listing
vibe revert app.vibeapp          # strip saved state, restore original
```

**`vibe init <name>` creates:**
```
<name>/
  vibe.yaml       ← manifest (nginx:alpine serving index.html on port 80)
  index.html      ← Hello World page (edit this)
  .vibeignore     ← exclusion rules
```
Do NOT run `vibe init` when adding Vibe to an existing project — write `vibe.yaml` directly in the project root instead (see workflow below).

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

## Adding Vibe to an Existing Project

Do NOT run `vibe init` — it creates a new subdirectory. Instead:

1. Write `vibe.yaml` in the project root
2. Write `.vibeignore` in the project root (copy the template below)
3. Run `vibe validate vibe.yaml`
4. Run `vibe package vibe.yaml -o <name>.vibeapp`

**Starter `.vibeignore` for any project:**
```
node_modules/
target/
dist/
build/
*.log
__pycache__/
*.pyc
```

## Common Service Command Patterns

The `command` field is the container entrypoint. The container starts fresh on each launch — install deps and start the server in one command using `sh -c`.

**Node.js — install + run (development-style, no build step):**
```yaml
image: node:20-alpine
command: ["sh", "-c", "npm install && node server.js"]
```

**Node.js — install + build + serve static output (Vite, CRA, etc.):**
```yaml
image: node:20-alpine
command: ["sh", "-c", "npm install && npm run build && npx serve dist -l 3000"]
ports:
  - container: 3000
```

**Node.js — install + build + start (Next.js, Express with build step):**
```yaml
image: node:20-alpine
command: ["sh", "-c", "npm install && npm run build && npm start"]
```

**Python — install + run:**
```yaml
image: python:3.12-alpine
command: ["sh", "-c", "pip install -r requirements.txt && python app.py"]
```

**Static site (files in package, served by nginx):**
```yaml
image: nginx:alpine
command: ["sh", "-c", "cp -r /app/. /usr/share/nginx/html && nginx -g 'daemon off;'"]
ports:
  - container: 80
```

**Postgres (database-only service, no command needed):**
```yaml
image: postgres:16
env:
  POSTGRES_PASSWORD: "secret"
  POSTGRES_DB: "mydb"
# no ports — only accessible to other services in the same app
```

**Key points:**
- `node_modules/` is excluded from the package — the container installs deps at startup via `npm install`
- If the app needs build-time env vars (e.g. `VITE_*`), set them in `env:` so they're available during `npm run build` inside the container
- Use `dependOn` to ensure databases start before the web service

## File Exclusion (`.vibeignore`)

`vibe package` excludes files via `.vibeignore` in the project root (created automatically by `vibe init`).

**Always excluded (built-in, no entry needed):** `node_modules/`, `target/`, hidden files (`.`-prefixed), `*.vibeapp`, `*.sig`

**`.vibeignore` syntax:**
- One pattern per line; `#` = comment
- Pattern **without** `/` → matches any file or directory with that name at any depth
- Pattern **with** `/` → matched against the path relative to the project root
- `*` matches any sequence of chars; `?` matches one char

```
# Common additions for a Node.js app:
dist/
build/
*.log
```

**When to create/edit `.vibeignore`:**
- Build artifacts shouldn't be bundled (`dist/`, `build/`) — the container should build at runtime
- Language-specific dependency dirs not caught by built-ins (e.g. Python `venv/`, `__pycache__/`)
- Large generated files that bloat the package

## Packaging Workflow (step-by-step)

1. Check `vibe.yaml` exists; if not, run `vibe init <name>` first
2. Check `.vibeignore` exists; add entries for any large/generated dirs (e.g. `dist/`)
3. Run `vibe validate vibe.yaml` — fix all errors before proceeding
4. Derive output filename from `id` last segment (e.g. `com.example.todo` → `todo.vibeapp`)
5. Run `vibe package vibe.yaml -o <name>.vibeapp` (add `--password` to encrypt)
6. If `signing.key` exists → run `vibe sign <name>.vibeapp --key signing.key`
7. Run `vibe inspect <name>.vibeapp` — confirm contents; check "Excluded:" count in output
8. If no signing key, remind: run `vibe keygen -o signing` to generate one

## Common Mistakes

- Large `.vibeapp` (>5 MB) — almost always caused by missing `.vibeignore` entries; check for `node_modules/`, `dist/`, `build/`, virtual envs
- Missing `kind: vibe.app/v1` (required, exact string)
- `id` with only one segment (e.g. `myapp` instead of `com.example.myapp`)
- Referencing a volume in `mounts` without declaring it in `state.volumes`
- Lowercase env var names in `env:` map (must be `UPPER_CASE`)
- Using `dependsOn` instead of `dependOn`
- Using `depends_on` (Docker Compose style) instead of `dependOn`
- Forgetting semver format for `version` (e.g. writing `1.0` instead of `1.0.0`)

Full schema reference: `docs/manifest-v1.md`
