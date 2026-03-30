# Security Model v1

Version: v1

## Package Encryption

`.vibeapp` packages can be password-protected using AES-256-GCM encryption with Argon2id key derivation. This prevents inspection of the manifest, assets, and seed data by anyone without the password.

### Encryption Format

An encrypted `.vibeapp` is a ZIP containing exactly two entries:

| Entry | Contents |
|---|---|
| `_vibe_encryption.json` | KDF and cipher metadata |
| `_vibe_encrypted_payload` | AES-256-GCM ciphertext (16-byte GCM tag appended) |

The **plaintext** is the complete inner `.vibeapp` ZIP. Encryption is applied as an outer wrapper — the inner package structure is preserved intact after decryption.

`_vibe_encryption.json` schema:
```json
{
  "version": 1,
  "cipher": "aes-256-gcm",
  "kdf": "argon2id",
  "kdf_params": {
    "m_cost": 65536,
    "t_cost": 3,
    "p_cost": 4,
    "salt": "<64 hex chars>"
  },
  "nonce": "<24 hex chars>"
}
```

**KDF parameters** follow the OWASP interactive profile: m=65536 (64 MiB), t=3, p=4. A fresh random 32-byte salt and 12-byte nonce are generated on every encryption.

### CLI Usage

```bash
# Create an encrypted package
vibe package vibe.yaml -o app.vibeapp --password <pass>
vibe package vibe.yaml -o app.vibeapp --password-file secrets/pw.txt

# Inspect / verify / sign / revert — all accept the same flags
vibe inspect app.vibeapp --password <pass>
vibe verify  app.vibeapp --key signing.pub --password <pass>
vibe sign    app.vibeapp --key signing.key --password <pass>
vibe revert  app.vibeapp --password <pass>

# Omit --password to be prompted interactively (most secure — not stored in shell history)
vibe inspect app.vibeapp
```

### Host App Behaviour

1. On open, the host detects `_vibe_encryption.json` and shows a password prompt.
2. The package is decrypted in memory; plain bytes are never written to disk.
3. On every auto-save (every 30 s) and explicit save, the package is re-encrypted with the same password and a fresh random nonce before being written.
4. The password is held in memory for the document session and cleared on close.

### Security Properties

- Wrong password or corrupted ciphertext → decryption fails with a clear error; the app is never opened.
- Each encryption call produces unique ciphertext (fresh salt + nonce), so repeated saves are not linkable.
- The encryption wrapper is independent of the trust/signature model — a package can be encrypted **and** signed.

---

## Trust Model

Every `.vibeapp` package is assigned one of five trust states at open time.

### Trust States

| State | Condition | UI Treatment |
|---|---|---|
| **Verified** | Valid Ed25519 signature from the Vibe root key (bundled in the app) | Green badge. No prompt. |
| **Trusted (TOFU)** | Valid signature from a key the user has previously trusted | Blue badge. No prompt. |
| **New Publisher** | Valid signature, but the key has not been seen before | Orange badge. One-time trust prompt. |
| **Unsigned (Dev Mode)** | No signature present. Intended for local development | Yellow warning. User acknowledges running unsigned code. |
| **Tampered** | Signature present but verification fails, or file digests do not match | Red block. App cannot be opened. |

### Publisher Key Resolution

The host resolves the public key to use for verification in this order:

1. **Embedded in package** — `publisher.signing.publicKeyFile` in the app manifest points to a 32-byte Ed25519 public key file inside the `.vibeapp` archive. If present and the file is exactly 32 bytes, it is used.
2. **Vibe root key** — the 32-byte Ed25519 public key bundled inside the Vibe app bundle (`demo-signing.pub`). Used as fallback when no key is embedded.

If neither source yields a valid 32-byte key, the package is treated as **unsigned**.

### Trust On First Use (TOFU)

Vibe implements TOFU for packages signed with self-generated developer keys:

1. On first open of a package from an unknown publisher:
   - The signature is verified cryptographically (proves integrity — package was not tampered with).
   - A **"New Publisher"** prompt is shown with the publisher name and key fingerprint.
   - The user can **"Trust Publisher"** (remembers the key permanently) or **"Open Once"** (runs this session without storing trust).

2. On subsequent opens of a package from the same key:
   - If the key was previously trusted: silent green badge (**Trusted**), no prompt.
   - If the key was declined or never stored: prompt is shown again.

3. Trust decisions are stored in:
   ```
   ~/Library/Application Support/Vibe/trusted-publishers.json
   ```
   Each entry records the full SHA-256 fingerprint of the key, the publisher name, and the timestamp.

### Verification Flow

1. Extract `_vibe_signature.sig` from the package archive.
2. If absent → **Unsigned**.
3. Attempt to extract the public key from the path in `publisher.signing.publicKeyFile`; fall back to the bundled Vibe root key.
4. If no valid 32-byte key is available → **Unsigned**.
5. Verify the Ed25519 signature over the package hash (SHA-256 of the sorted file-digest JSON).
6. If signature invalid → **Tampered**.
7. Verify each file's SHA-256 hash against the package manifest.
8. If any hash mismatches → **Tampered**.
9. If the key matches the Vibe root key → **Verified**.
10. If the key fingerprint is in the user's trust store → **Trusted (TOFU)**.
11. Otherwise → **New Publisher** (trust prompt shown before launch).

### Key Fingerprints

The trust store identifies keys by their **full SHA-256 fingerprint**: SHA-256 of the raw 32-byte Ed25519 public key, hex-encoded (64 characters).

For UI display, a **short fingerprint** is shown: the first 16 hex characters in groups of 4 (e.g., `a1b2 c3d4 e5f6 7890`).

### Future: Vibe Registry

The TOFU model is the v1 trust mechanism. A planned v2 upgrade will add a Vibe-operated key registry where publishers can register and receive a countersignature from the Vibe root. Packages from registered publishers will show **Verified** automatically without a user prompt.

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
