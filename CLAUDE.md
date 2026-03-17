# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**Vibe** is a macOS-native containerized application runtime. Apps are defined in `vibe.yaml` manifests, packaged as signed `.vibeapp` archives, and run inside a persistent Alpine Linux VM using containerd. The host UI is a Swift macOS app; CLI tooling and cryptographic operations are in Rust.

## Build Commands

```bash
make bootstrap      # Install Rust components (clippy, rustfmt), verify Swift
make build          # Build Rust workspace + Swift host app
make test           # Run Rust + Swift test suites
make lint           # cargo clippy --workspace -- -D warnings
make fmt            # Format Rust code
make fmt-check      # Check formatting without modifying
make bundle-vm      # Build Alpine Linux VM image → copies kernel/initrd to Resources/
make demo-packages  # Generate signed demo .vibeapp files in build/demo/
make demo-verify    # Verify all demo packages
make clean          # Clean all build artifacts
```

### Targeted builds

```bash
cargo build --workspace
cargo build -p vibe-cli --release
cargo test --lib -p vibe-manifest        # Manifest validation tests only
cargo test --lib -p vibe-signing         # Signing/crypto tests only
cd apps/mac-host && swift build
cd apps/mac-host && swift test
```

### CLI usage

```bash
cargo run --bin vibe -- --help
cargo run --bin vibe -- init <name>
cargo run --bin vibe -- validate [vibe.yaml]
cargo run --bin vibe -- package <manifest> -o out.vibeapp
cargo run --bin vibe -- sign <package> --key signing.key
cargo run --bin vibe -- verify <package> --key signing.pub
cargo run --bin vibe -- keygen -o output
cargo run --bin vibe -- inspect <package>
cargo run --bin vibe -- revert <package>   # Strip _vibe_state/ from package
```

## Architecture

### Components

| Component | Language | Location | Role |
|---|---|---|---|
| `vibe-cli` | Rust | `apps/cli/` | Package, sign, verify, inspect `.vibeapp` files |
| `vibe-manifest` | Rust | `libs/manifest/` | Manifest struct, YAML parsing, validation |
| `vibe-signing` | Rust | `libs/signing/` | Ed25519 keygen, sign, verify, SHA-256 hashing |
| `VibeHost` | Swift | `apps/mac-host/` | macOS UI, VM lifecycle, project library |
| VM image | Shell | `vm-image/` | Alpine Linux builder (no Docker required) |

### Packaging & signing flow

1. **Init** → creates `vibe.yaml` template
2. **Validate** → checks kind, services, dependency cycles (DFS), path traversal, port ranges
3. **Package** → ZIP archive of manifest + assets + optional seed data
4. **Sign** → deterministic SHA-256 hash of all files (BTreeMap sorted), Ed25519 signature
5. **Verify** → checks signature; host app enforces trust before launch
6. **Revert** → strips `_vibe_state/` to restore original signed content

### macOS host runtime

- `VMManager.swift` — VM lifecycle via Apple Virtualization framework (single persistent Alpine Linux VM)
- `ProjectLifecycleManager.swift` — Project registration, open/start/stop, state snapshot coordination
- `ContainerRuntimeClient.swift` — RPC to VM supervisor over vsock
- `PackageExtractor.swift` — ZIP extraction and state unpacking
- `StorageManager.swift` — Package cache on persistent data disk, state directory layout
- `PackageVerifier.swift` — Validates Ed25519 signatures using embedded public key
- `VibeSchemeHandler.swift` — `WKURLSchemeHandler` for internal scheme routing

State snapshots are saved as `_vibe_state/<timestamp>.tar.gz`, auto-saved every 30s, max 100 snapshots.

### Manifest format (`vibe.app/v1`)

```yaml
kind: vibe.app/v1
id: com.example.app
name: App Name
version: 1.0.0

services:
  - name: web
    image: node:20-alpine
    command: ["node", "server.js"]
    ports:
      - container: 3000
    dependOn: ["db"]
  - name: db
    image: postgres:16

state:
  volumes:
    - name: data
      consistency: postgres   # postgres | generic

security:
  network: true
  allowHostFileImport: false

secrets:
  - name: API_KEY
    required: true

publisher:
  name: Publisher Name
```

### CI

- **Rust** job (Ubuntu): build, test, clippy, rustfmt check
- **Swift** job (macOS 14): build, test
- Triggers: push to `main`, all PRs
- Cargo caching: registry, git, target directories

## Key docs

- `docs/spec.md` — Full implementation spec
- `docs/manifest-v1.md` — Manifest schema
- `docs/rpc-api-v1.md` — VSock RPC API
- `docs/security-model-v1.md` — Trust and security model
- `docs/snapshot-protocol-v1.md` — Save/restore protocol
- `docs/state-layout-v1.md` — State directory layout
