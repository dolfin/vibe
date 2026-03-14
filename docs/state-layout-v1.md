# State Layout v1

Version: v1

## Directory Structure

```
state/
  current/
    files/
    volumes/
    runtime/
      env.json
      ports.json
      service-state.json
  snapshots/
    <timestamp>/
      files/
      volumes/
      metadata.json
  index.json
```

## Directory Reference

### `state/`

Root of all mutable state for a single project instance. Each project instance has its own state directory, completely independent from the immutable package.

### `state/current/`

The live working state. This is what running services read from and write to.

#### `state/current/files/`

General-purpose file storage for the app. Mounts declared with `source: state:<name>` in the manifest bind into this area. Example: user uploads, generated assets, local caches.

#### `state/current/volumes/`

Named volumes used by services. Each subdirectory corresponds to a volume declared in `state.volumes` in the manifest. Example: `volumes/dbdata/` holds the Postgres data directory.

#### `state/current/runtime/`

Runtime metadata files managed by the supervisor. These are not user data --- they track the operational state of the project.

##### `env.json`

Resolved environment variables for each service (excluding secrets, which are injected at start time and never persisted).

```json
{
  "services": {
    "web": {
      "NODE_ENV": "production",
      "DATABASE_URL": "postgres://todo@db:5432/todo"
    },
    "db": {
      "POSTGRES_DB": "todo",
      "POSTGRES_USER": "todo"
    }
  }
}
```

##### `ports.json`

Current host-to-container port mappings.

```json
{
  "mappings": [
    {
      "service": "web",
      "containerPort": 3000,
      "hostPort": 49231,
      "protocol": "tcp"
    }
  ]
}
```

##### `service-state.json`

Current lifecycle state of each service.

```json
{
  "services": {
    "web": {
      "status": "running",
      "containerId": "abc123",
      "startedAt": "2026-03-13T12:00:00Z",
      "restartCount": 0
    },
    "db": {
      "status": "running",
      "containerId": "def456",
      "startedAt": "2026-03-13T11:59:58Z",
      "restartCount": 0
    }
  }
}
```

**Valid status values:** `stopped`, `starting`, `running`, `stopping`, `failed`

### `state/snapshots/`

Contains saved snapshots. Each snapshot lives in a timestamp-named subdirectory.

#### `state/snapshots/<timestamp>/`

Timestamp format: ISO 8601 with colons replaced by hyphens for filesystem safety. Example: `2026-03-13T12-00-00Z`

##### `state/snapshots/<timestamp>/files/`

Copy of `current/files/` at snapshot time. In the chunked content-addressed store, this is replaced by chunk references in the metadata.

##### `state/snapshots/<timestamp>/volumes/`

Copy of `current/volumes/` at snapshot time. For volumes with `consistency: postgres`, this directory contains the logical dump rather than raw data files. For `consistency: sqlite`, this contains the checkpointed DB file.

##### `state/snapshots/<timestamp>/metadata.json`

Snapshot metadata.

```json
{
  "snapshotId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "timestamp": "2026-03-13T12:00:00Z",
  "parentSnapshotId": "prev-snapshot-uuid-or-null",
  "reason": "manual",
  "appVersion": "1.0.0",
  "stateDigest": "sha256:abcdef1234567890...",
  "volumeManifests": {
    "dbdata": {
      "consistency": "postgres",
      "dumpFormat": "pg_dump_custom",
      "sizeBytes": 1048576,
      "digest": "sha256:..."
    },
    "uploads": {
      "consistency": "generic",
      "sizeBytes": 524288,
      "digest": "sha256:..."
    }
  },
  "labels": {
    "user-label": "before refactor"
  }
}
```

**`reason` enum values:** `manual`, `autosave`, `before-upgrade`, `before-restore`

### `state/index.json`

Top-level index tracking all snapshots and current state metadata. Updated atomically on every save or restore.

```json
{
  "projectId": "uuid",
  "appId": "com.example.todo",
  "currentStateDigest": "sha256:...",
  "snapshots": [
    {
      "snapshotId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "timestamp": "2026-03-13T12:00:00Z",
      "parentSnapshotId": null,
      "reason": "manual",
      "appVersion": "1.0.0",
      "stateDigest": "sha256:...",
      "labels": {
        "user-label": "before refactor"
      }
    }
  ],
  "retentionPolicy": {
    "maxSnapshots": 100
  },
  "lastModified": "2026-03-13T12:00:00Z"
}
```

## Atomicity and Safety

- `index.json` is always updated atomically (write to temp file, fsync, rename)
- A crash during snapshot save must never corrupt `current/`
- A crash during snapshot save must leave the last good snapshot intact
- Snapshot directories are immutable once written --- never modified in place
