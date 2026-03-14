# Security Model v1

Version: v1

## Trust Model

Every `.vibeapp` package is assigned one of four trust states at open time.

### Trust States

| State | Condition | UI Treatment |
|---|---|---|
| **Signed + Trusted** | Valid Ed25519 signature from a publisher in the user's trust store | Green trust indicator. Capabilities shown but not gated |
| **Signed + Untrusted** | Valid signature, but publisher is not in the user's trust store | Yellow warning. User prompted to trust publisher or proceed cautiously |
| **Unsigned (Dev Mode)** | No signature present. Intended for local development | Orange warning. User explicitly acknowledges running unsigned code |
| **Tampered** | Signature present but verification fails, or file digests do not match manifest | Red block. App cannot be opened. User sees tamper explanation |

### Verification Flow

1. Check for `publisher.signing` in manifest
2. If absent, classify as **unsigned**
3. If present, verify detached signature against public key and root manifest hash
4. If signature is invalid or file digests mismatch, classify as **tampered** and block
5. If signature is valid, check whether publisher public key is in user's trust store
6. Classify as **trusted** or **untrusted** accordingly

## Capability Prompts

The manifest declares capabilities the app requests. These are shown to the user before first run.

| Capability | Manifest Field | Prompt Description |
|---|---|---|
| **Network access** | `security.network: true` | This app requests outbound internet access |
| **Host file import** | `security.allowHostFileImport: true` | This app can import files from your Mac |
| **Port exposure** | Any service with `ports[].hostExposure: auto` | This app will listen on a local network port |
| **Background execution** | (future, deferred in v1) | This app requests running when the window is closed |
| **Large disk usage** | (triggered by state size exceeding threshold) | This app may use significant disk space |

### Prompt Behavior

- Capabilities are shown in a single prompt at first open
- User can accept all, reject individual capabilities, or cancel
- Rejected capabilities disable the corresponding feature (e.g., no network = no outbound traffic)
- Decisions are persisted per project instance
- User can change capability decisions in project settings

## Runtime Hardening

All containers run with restrictive defaults. No container in v1 runs privileged.

### Default Container Security

| Policy | Setting |
|---|---|
| **Drop capabilities** | All Linux capabilities dropped by default. Only `NET_BIND_SERVICE` retained if the service binds to ports < 1024 |
| **Read-only root filesystem** | Enabled where possible. Services that need writable root get explicit writable overlay mounts |
| **No host PID namespace** | Containers never share the host PID namespace |
| **No privileged mode** | `privileged: true` is rejected in v1, both in native manifest and Compose import |
| **Limited writable mounts** | Only explicitly declared volumes and state mounts are writable. All other paths are read-only |
| **No host network** | Containers use project-scoped bridge networking, never host network mode |
| **No device passthrough** | No `/dev` device mounts in v1 |

### Network Isolation

- Each project gets its own CNI network
- Inter-project network traffic is blocked
- Outbound internet access is gated by the `security.network` capability
- If network capability is denied, all outbound traffic is blocked (except inter-service within the project)

## Secret Handling

Secrets are never stored in the immutable package in plaintext. Two methods are supported.

### Method A --- User-Provided Secrets (Recommended Default)

The manifest declares required secrets:

```yaml
secrets:
  - name: OPENAI_API_KEY
    required: true
  - name: AWS_SECRET_ACCESS_KEY
    required: false
```

**Flow:**

1. On first open, the host app detects missing secrets
2. User is prompted to enter each secret value
3. Secrets are stored in the **macOS Keychain**, scoped to the project instance
4. At service start, secrets are injected as environment variables

**Properties:**
- Secrets never exist inside the package
- Secrets persist across project restarts
- Secrets are scoped per project instance (not shared between instances of the same app)
- Deleting a project instance removes its Keychain entries

### Method B --- Encrypted Secrets in Package

For distribution models where developers ship pre-configured secrets.

The package contains an encrypted blob:

```
secrets.encrypted
```

**Contents:**
- Encrypted secret values
- Encryption metadata (cipher, nonce)
- Key derivation parameters

**Flow:**

1. On open, user is prompted for a decryption password
2. Host derives key using **Argon2id** (or scrypt)
3. Host decrypts using **AES-256-GCM** (or ChaCha20-Poly1305)
4. Decrypted secrets are held in memory only
5. Secrets are injected into the runtime environment

**Brute-force protection:**
- Exponential backoff after failed decryption attempts
- Temporary lock (5 minutes) after 5 consecutive failures
- Attempt counter resets on success

**Requirement:** Decrypted secrets are never written back to disk in plaintext.

### Runtime Injection

Regardless of storage method, secrets reach services via:

- **Environment variables** --- secret name becomes the env var name
- **Mounted secret files** --- optional, for services that read secrets from files rather than env

### Secret Safety Guarantees

- Secrets never appear in logs (log collector redacts known secret names)
- Secrets never appear in snapshots (excluded from state copy)
- Secrets are not stored in the immutable package (plaintext)
- Keychain-backed secrets survive app restarts
- Secrets are isolated per project instance and never leak between apps
