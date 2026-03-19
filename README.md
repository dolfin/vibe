# Vibe

[![CI](https://github.com/dolfin/vibe/actions/workflows/ci.yml/badge.svg)](https://github.com/dolfin/vibe/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Turn AI-built apps into files you can share and open anywhere.**

Vibe lets you package an AI-built app into a single file and send it to anyone. They can open it with the Vibe player on their Mac and run it safely — no setup, no terminals, no dev stack required. Sharing software feels like sending a file, not deploying an app.

---

## Features

- **One file to share** — your whole app ships as a single `.vibeapp`
- **No installation for recipients** — opens like any document on macOS
- **Runs safely in a sandbox** — fully isolated from the host system
- **Password protection** — optionally encrypt packages before sharing
- **State is preserved** — apps remember what they were doing between sessions
- **Works with any AI-built stack** — Node, Python, Postgres, anything containerized

---

## Requirements

- **macOS 14 (Sonoma) or later** — to open `.vibeapp` files
- **Rust toolchain** — only needed to build from source or package apps

---

## Getting Started

### Open a `.vibeapp`

Download **Vibe for Mac** from the [Releases page](https://github.com/dolfin/vibe/releases) and double-click any `.vibeapp` file.

### Package an app

```bash
brew tap dolfin/vibe && brew install vibe

vibe init myapp
# edit vibe.yaml
vibe package vibe.yaml -o myapp.vibeapp
```

Share `myapp.vibeapp` with anyone running macOS 14+.

---

## CLI Reference

| Command | Description |
|---|---|
| `vibe init <name>` | Create a new `vibe.yaml` manifest |
| `vibe validate [vibe.yaml]` | Validate a manifest |
| `vibe package <manifest> -o out.vibeapp` | Package an app |
| `vibe package <manifest> -o out.vibeapp --password <pass>` | Package with encryption |
| `vibe sign <package> --key signing.key` | Sign a package |
| `vibe verify <package> --key signing.pub` | Verify a package signature |
| `vibe inspect <package>` | Inspect package contents |
| `vibe revert <package>` | Strip saved state from a package |
| `vibe keygen -o output` | Generate an Ed25519 signing keypair |

---

## How It Works

Vibe has two parts: a **CLI** (for developers) and a **macOS player** (for everyone).

**Packaging (CLI)**
1. Write a `vibe.yaml` manifest describing your app's services
2. `vibe package` bundles everything into a ZIP-based `.vibeapp` archive
3. `vibe sign` signs the package with Ed25519; SHA-256 hashes every file
4. Optionally encrypt with AES-GCM via `--password`

**Running (macOS app)**
1. The host app verifies the Ed25519 signature before launching
2. A persistent Alpine Linux VM starts via Apple's Virtualization framework
3. containerd runs your app's services inside the VM
4. State snapshots save automatically every 30 seconds (up to 100 per app)

---

## Architecture

| Component | Language | Role |
|---|---|---|
| `vibe-cli` | Rust | Package, sign, verify, inspect `.vibeapp` files |
| `vibe-manifest` | Rust | Manifest parsing and validation |
| `vibe-signing` | Rust | Ed25519 keygen, sign, verify, SHA-256 hashing |
| `Vibe` (macOS) | Swift | macOS UI, VM lifecycle, project library |

---

## Building from Source

```bash
git clone https://github.com/dolfin/vibe.git
cd vibe
make bootstrap   # install Rust components, verify Swift
make build       # build Rust workspace + Swift host app
make test        # run Rust + Swift test suites
```

To build just the CLI:

```bash
cargo build -p vibe-cli --release
```

---

## License

MIT — see [LICENSE](LICENSE)
