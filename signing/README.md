# Signing

This directory holds the official Vibe signing key used to produce the demo apps
that ship inside the macOS app bundle. The public key is committed; the private key
is not and must be obtained separately.

## Files

| File | Committed | Purpose |
|---|---|---|
| `vibe-official.pub` | Yes (in Resources/) | Ed25519 public key — bundled in the app, establishes root-of-trust |
| `vibe-official.key` | **No** | Ed25519 private key — place here to sign bundled demos locally |

`*.key` is listed in this directory's `.gitignore` and will never be committed.

## How to get the key

The private key is stored as the `VIBE_SIGNING_KEY` GitHub Actions repository secret
(base64-encoded 32-byte Ed25519 key). To sign bundled demos on your local machine:

```bash
# Decode the secret value and write it here:
echo "<base64-value>" | base64 -d > signing/vibe-official.key
```

Then run:

```bash
make bundle-demos
```

## Developer workflow (no official key needed)

Every developer can build and sign all demo apps with a locally-generated key:

```bash
make dev-keygen      # one-time: generates build/dev/signing.{key,pub}
make demo-packages   # builds all examples, signs with your dev key
```

Packages signed with a dev key will show "New Publisher" in the app the first time
they are opened (TOFU prompt). This is expected for local development builds.
