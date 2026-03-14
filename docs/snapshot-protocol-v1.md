# Snapshot Protocol v1

Version: v1

## Snapshot Object Model

Every snapshot contains:

| Field | Type | Description |
|---|---|---|
| `snapshotId` | string (UUID) | Unique identifier |
| `timestamp` | string (ISO 8601) | Creation time |
| `parentSnapshotId` | string or null | Previous snapshot in chain (null for first) |
| `reason` | enum | `manual`, `autosave`, `before-upgrade`, `before-restore` |
| `appVersion` | string | App version at time of snapshot |
| `stateDigest` | string | SHA-256 digest over all snapshot content |
| `volumeManifests` | map | Per-volume metadata (consistency type, format, size, digest) |
| `dbExports` | map | Optional. Keyed by volume name; contains export format and path |
| `labels` | map | User-defined key-value labels |

## Save Algorithm

The save flow executes these 10 steps in order:

1. **Resolve target project** --- look up the project in the registry, confirm it exists and has a valid state path
2. **Block new write-affecting lifecycle operations** --- acquire an exclusive save lock; reject concurrent start/stop/restore/save requests for this project
3. **Run pre-save hooks per service** --- execute consistency hooks based on each volume's `consistency` type (see SQLite and Postgres sections below)
4. **Wait for quiesce** --- confirm all pre-save hooks have completed and data is flushed to disk
5. **Checkpoint state** --- create a point-in-time marker; for generic volumes, pause or snapshot at the filesystem level
6. **Copy current state to snapshot workspace** --- copy `current/files/` and `current/volumes/` into a new snapshot directory under `snapshots/<timestamp>/`
7. **Compute snapshot metadata** --- hash all snapshot content, build volume manifests, generate `metadata.json`
8. **Atomically update index.json** --- write new index to temp file, fsync, rename over existing `index.json`
9. **Release lock** --- remove the exclusive save lock, allowing lifecycle operations to proceed
10. **Resume services** --- if any services were paused for consistency, resume them

**Failure guarantee:** If any step fails, the save aborts cleanly. `current/` is never modified during a save. The last good snapshot remains intact. Partial snapshot directories are cleaned up.

## SQLite Consistency Protocol

For each volume or file marked with `consistency: sqlite`:

1. **Ensure no write migration running** --- check that no schema migration is actively writing to the DB
2. **Run WAL checkpoint** --- execute `PRAGMA wal_checkpoint(TRUNCATE)` to flush the write-ahead log into the main DB file
3. **Fsync DB and directory** --- fsync the DB file and its parent directory to ensure durability
4. **Copy DB artifact** --- copy the `.db` file (WAL is now empty) into the snapshot workspace
5. **Record integrity result** --- run `PRAGMA integrity_check` on the copy and store the result in volume manifest metadata

## Postgres Consistency

For volumes marked with `consistency: postgres`:

### Logical Dump (primary method)

- Execute `pg_dump` in custom format against the running Postgres instance
- Store the dump file in the snapshot's `volumes/` directory
- Record dump format, database name, size, and digest in the volume manifest

### Optional Raw Volume Copy (fast local restore)

- Optionally keep a raw copy of the Postgres data directory alongside the logical dump
- This copy is only used for fast local restore, not for portability
- The logical dump remains the authoritative portable format

### Consistency Guarantees

- Logical dump provides a transaction-consistent view without stopping the database
- If dump fails, the save operation fails (no partial snapshots)
- Dump is validated by checking `pg_dump` exit code and output size

## Generic Volume Handling

For volumes marked with `consistency: generic`:

1. **Pause write-heavy containers** --- if the service has no custom save hook, pause or stop the container to prevent writes during copy
2. **Copy volume content** --- tar or chunk-copy the entire volume directory
3. **Hash manifest** --- compute content digest over copied data
4. **Compress** --- optionally compress in background after the snapshot is committed
5. **Resume containers** --- unpause or restart containers that were paused

If a pre-save hook is registered for the service, it runs instead of the generic pause-and-copy.

## Chunked Content-Addressed Storage

Snapshot data is stored using a content-addressed chunk store to control state growth across many snapshots.

### Chunking

- Large files are split into fixed-size or content-defined chunks (target chunk size: 1 MiB, configurable)
- Each chunk is identified by its SHA-256 digest
- Small files (below chunk threshold) are stored as a single chunk

### Deduplication

- Chunks are stored once in the chunk store, regardless of how many snapshots reference them
- The chunk store is shared across all snapshots for a project
- Identical data across snapshots (unchanged files, unchanged DB pages) is stored only once

### Snapshot Manifest

Each snapshot's `metadata.json` references chunk digests rather than storing full file copies:

```json
{
  "files": [
    {
      "path": "files/uploads/photo.jpg",
      "size": 2097152,
      "chunks": [
        "sha256:aaa111...",
        "sha256:bbb222..."
      ]
    }
  ]
}
```

### Chunk Store Layout

```
state/
  chunks/
    aa/
      sha256:aaa111...    # chunk data
    bb/
      sha256:bbb222...    # chunk data
  ...
```

Chunks are organized by digest prefix for filesystem scalability.

### Garbage Collection

- A chunk is reclaimable when no snapshot manifest references it
- GC runs periodically or on explicit trigger
- GC is safe to run concurrently with reads (mark-and-sweep: mark all referenced chunks, sweep unreferenced)
