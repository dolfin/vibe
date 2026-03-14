# Vibe Runtime v1 Scope

Version: v1

## In Scope

### Host Environment
- **macOS app host** --- the only supported host platform for v1
- **One persistent Linux VM** --- single warm VM, booted at app launch, shared by all projects
- **One containerd daemon** in the VM --- all container workloads run through this single daemon
- **One namespace per app** --- each opened project gets its own containerd namespace for isolation

### Package Model
- **Immutable package + mutable state** --- `.vibeapp` packages are read-only; all user data lives in a separate mutable state directory
- **Native manifest** --- `vibe.app/v1` YAML manifest as the primary app definition format
- **Compose import mode** --- existing `compose.yaml` files can be imported and translated into the native runtime model (supported subset only)

### Persistence
- **SQLite** --- WAL checkpoint + fsync protocol for consistent snapshots
- **Postgres** --- logical dump for portable snapshots, optional raw volume copy for fast local restore

### Snapshot System
- **Snapshot save/restore** --- manual and autosave, with content-addressed chunked storage
- **Snapshot deduplication** --- chunk-level dedup to control state growth

### Networking
- **Host port forwarding** --- container ports are exposed to the macOS host via collision-safe port allocation

### Lifecycle Operations
- `logs` --- stream service stdout/stderr to the UI
- `start` --- start a project's services
- `stop` --- stop a project's services
- `save` --- create a snapshot of current state
- `restore` --- revert to a previous snapshot
- `duplicate` --- clone a project with independent mutable state

## Explicitly Deferred (Not v1)

| Feature | Reason |
|---|---|
| Multi-user collaboration | Requires account system, conflict resolution, and sync protocol |
| Cloud sync | Requires cloud infrastructure, auth, and bandwidth management |
| Distributed snapshots | Requires content-addressed remote storage and transfer protocol |
| Live migration | Requires VM state serialization and cross-host restore |
| Build-your-own image pipeline in the app UI | Adds significant complexity; developers use external tooling for v1 |
| Arbitrary Compose fidelity beyond supported subset | nerdctl documents unimplemented fields; full Compose parity is not a v1 goal |

## Acceptance Criteria

- Every feature in scope maps to an owner and test plan
- Every non-v1 feature is listed as deferred, not implied
- The feature set is sufficient to open a signed `.vibeapp`, run multi-service apps (web + DB), save/restore state, and manage project lifecycle entirely from the macOS UI
