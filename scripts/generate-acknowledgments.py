#!/usr/bin/env python3
"""
generate-acknowledgments.py

Reads Package.resolved (Swift) and Cargo.lock (Rust), finds the actual
license files from local package checkouts and the Cargo registry, and
writes apps/mac-host/VibeHost/Resources/Acknowledgments.json.

Run via:  make acknowledgments
      or:  python3 scripts/generate-acknowledgments.py
"""

import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).parent.parent
MAC_HOST = REPO_ROOT / "apps" / "mac-host"
SPM_CHECKOUTS = MAC_HOST / ".build" / "checkouts"
CARGO_LOCK = REPO_ROOT / "Cargo.lock"
PACKAGE_RESOLVED = MAC_HOST / "Package.resolved"
OUTPUT = MAC_HOST / "VibeHost" / "Resources" / "Acknowledgments.json"


def find_cargo_registry() -> Path:
    candidates = list((Path.home() / ".cargo" / "registry" / "src").glob("index.crates.io-*"))
    if not candidates:
        sys.exit("ERROR: ~/.cargo/registry/src/index.crates.io-* not found. Run `cargo build` first.")
    return sorted(candidates)[-1]


CARGO_REGISTRY = find_cargo_registry()

# ---------------------------------------------------------------------------
# Direct Rust dependencies we want to surface (from workspace Cargo.toml and
# apps/cli/Cargo.toml – transitive deps are intentionally omitted).
# ---------------------------------------------------------------------------

RUST_DIRECT_DEPS = [
    "serde",
    "serde_json",
    "serde_yaml",
    "thiserror",
    "anyhow",
    "clap",
    "clap_mangen",
    "semver",
    "sha2",
    "aes-gcm",
    "argon2",
    "ed25519-dalek",
    "rand",
    "zip",
    "colored",
    "chrono",
    "rpassword",
]

# Authoritative source URLs (Cargo.toml often omits or has the wrong one)
RUST_URL_OVERRIDE: dict[str, str] = {
    "serde":          "https://github.com/serde-rs/serde",
    "serde_json":     "https://github.com/serde-rs/json",
    "serde_yaml":     "https://github.com/dtolnay/serde-yaml",
    "thiserror":      "https://github.com/dtolnay/thiserror",
    "anyhow":         "https://github.com/dtolnay/anyhow",
    "clap":           "https://github.com/clap-rs/clap",
    "clap_mangen":    "https://github.com/clap-rs/clap",
    "semver":         "https://github.com/dtolnay/semver",
    "sha2":           "https://github.com/RustCrypto/hashes",
    "aes-gcm":        "https://github.com/RustCrypto/AEADs",
    "argon2":         "https://github.com/RustCrypto/password-hashes",
    "ed25519-dalek":  "https://github.com/dalek-cryptography/curve25519-dalek",
    "rand":           "https://github.com/rust-random/rand",
    "zip":            "https://github.com/zip-rs/zip2",
    "colored":        "https://github.com/colored-rs/colored",
    "chrono":         "https://github.com/chronotope/chrono",
    "rpassword":      "https://github.com/conradkleinespel/rpassword",
}

# SPM identities to skip (transitive, not user-facing)
SPM_SKIP = {"phc-winner-argon2"}

# Display-name overrides for SPM packages (identity → nice name)
SPM_NAME_OVERRIDE: dict[str, str] = {
    "zipfoundation": "ZIPFoundation",
    "yams":          "Yams",
    "sparkle":       "Sparkle",
    "argon2swift":   "Argon2Swift",
}


# ---------------------------------------------------------------------------
# Parse Package.resolved
# ---------------------------------------------------------------------------

def read_spm_pins() -> list[dict]:
    with PACKAGE_RESOLVED.open() as f:
        data = json.load(f)
    pins = []
    for pin in data.get("pins", []):
        identity = pin["identity"]
        if identity in SPM_SKIP:
            continue
        state = pin.get("state", {})
        # For tagged releases use the semver string; for branch pins use the
        # branch name directly (no "v" prefix); fall back to short commit hash.
        raw = state.get("version") or state.get("branch") or state.get("revision", "")[:8]
        version = raw  # we only add "v" in the display layer if it looks like semver
        pins.append({
            "identity": identity,
            "url": pin["location"].rstrip("/"),
            "version": version,
        })
    return pins


# ---------------------------------------------------------------------------
# Parse Cargo.lock  (TOML – we avoid a TOML library dependency)
# ---------------------------------------------------------------------------

def read_cargo_versions() -> dict[str, str]:
    """Return {name: version} for every package in Cargo.lock."""
    text = CARGO_LOCK.read_text()
    versions: dict[str, str] = {}
    for block in re.split(r"\[\[package\]\]", text):
        name_m = re.search(r'^name\s*=\s*"([^"]+)"', block, re.MULTILINE)
        ver_m  = re.search(r'^version\s*=\s*"([^"]+)"', block, re.MULTILINE)
        if name_m and ver_m:
            n = name_m.group(1)
            v = ver_m.group(1)
            # Keep the first occurrence (in case of duplicates at different versions)
            if n not in versions:
                versions[n] = v
    return versions


# ---------------------------------------------------------------------------
# License file helpers
# ---------------------------------------------------------------------------

def _spdx_from_file(filename: str, content: str) -> str:
    upper_name = filename.upper()
    upper_body = content.upper()

    # Filename-based detection (most reliable)
    if "APACHE" in upper_name:
        return "Apache-2.0"
    if "MIT" in upper_name:
        return "MIT"
    if "BSD" in upper_name:
        return "BSD-3-Clause"
    if "MPL" in upper_name or "MOZILLA" in upper_name:
        return "MPL-2.0"

    # Body-based detection — check all matches and return combined SPDX when
    # a single file declares dual-licensing (e.g. chrono's LICENSE.txt).
    found: list[str] = []
    if "APACHE LICENSE" in upper_body or "APACHE 2" in upper_body:
        found.append("Apache-2.0")
    if (
        "MIT LICENSE" in upper_body
        or "PERMISSION IS HEREBY GRANTED" in upper_body
        or "THE MIT LICENSE" in upper_body
    ):
        found.append("MIT")
    if "MOZILLA PUBLIC LICENSE" in upper_body:
        found.append("MPL-2.0")
    # BSD-3: "Redistribution … permitted … neither the name"
    if "REDISTRIBUTION AND USE" in upper_body and "NEITHER THE NAME" in upper_body:
        found.append("BSD-3-Clause")
    elif "REDISTRIBUTION AND USE" in upper_body:
        found.append("BSD-2-Clause")

    if found:
        return " / ".join(dict.fromkeys(found))
    return "Unknown"


def read_license(package_dir: Path) -> tuple[str, str]:
    """
    Returns (spdx_expression, full_license_text).
    Combines multiple files (e.g. LICENSE-MIT + LICENSE-APACHE) into one text.
    """
    license_files = sorted(
        (p for p in package_dir.iterdir()
         if re.match(r"licen[cs]e|copying", p.name, re.IGNORECASE) and p.is_file()),
        key=lambda p: p.name.upper(),
    )
    if not license_files:
        return ("Unknown", "No license file found.")

    spdx_ids: list[str] = []
    sections: list[str] = []

    for lf in license_files:
        body = lf.read_text(errors="replace").strip()
        spdx_ids.append(_spdx_from_file(lf.name, body))
        if len(license_files) > 1:
            sections.append(f"────── {lf.name} ──────\n\n{body}")
        else:
            sections.append(body)

    spdx = " / ".join(dict.fromkeys(spdx_ids))   # deduplicated, order-preserving
    full_text = "\n\n".join(sections)
    return spdx, full_text


# ---------------------------------------------------------------------------
# Cargo.toml.orig metadata
# ---------------------------------------------------------------------------

def _toml_scalar(key: str, text: str) -> str:
    m = re.search(rf'^{re.escape(key)}\s*=\s*"([^"]*)"', text, re.MULTILINE)
    if m:
        return m.group(1)
    # Array form: key = ["a", "b"]
    m = re.search(rf'^{re.escape(key)}\s*=\s*\[([^\]]*)\]', text, re.MULTILINE)
    if m:
        return ", ".join(re.findall(r'"([^"]+)"', m.group(1)))
    return ""


def read_cargo_toml_meta(pkg_dir: Path) -> dict[str, str]:
    for name in ("Cargo.toml.orig", "Cargo.toml"):
        path = pkg_dir / name
        if path.exists():
            text = path.read_text(errors="replace")
            return {
                "authors":     _toml_scalar("authors", text),
                "description": _toml_scalar("description", text),
                "repository":  _toml_scalar("repository", text),
                "homepage":    _toml_scalar("homepage", text),
            }
    return {"authors": "", "description": "", "repository": "", "homepage": ""}


# ---------------------------------------------------------------------------
# Locate packages
# ---------------------------------------------------------------------------

def find_spm_checkout(identity: str) -> Path | None:
    # Direct match
    d = SPM_CHECKOUTS / identity
    if d.is_dir():
        return d
    # Case-insensitive fallback
    try:
        for item in SPM_CHECKOUTS.iterdir():
            if item.name.lower() == identity.lower():
                return item
    except FileNotFoundError:
        pass
    return None


def find_rust_pkg_dir(name: str, version: str) -> Path | None:
    # Exact match (version may contain metadata like "+deprecated")
    for candidate in (f"{name}-{version}", f"{name}-{version.split('+')[0]}"):
        d = CARGO_REGISTRY / candidate
        if d.is_dir():
            return d
    # Fallback: pick latest available version
    candidates = sorted(CARGO_REGISTRY.glob(f"{name}-*"))
    return candidates[-1] if candidates else None


# ---------------------------------------------------------------------------
# Build entries
# ---------------------------------------------------------------------------

def entry(name: str, version: str, url: str, spdx: str,
          license_text: str, authors: str) -> dict:
    return {
        "name":        name,
        "version":     version,
        "license":     spdx,
        "url":         url,
        "authors":     authors,
        "licenseText": license_text,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    results: list[dict] = []
    warnings: list[str] = []

    # ── Swift / SPM ────────────────────────────────────────────────────────
    for pin in read_spm_pins():
        identity = pin["identity"]
        display  = SPM_NAME_OVERRIDE.get(identity, identity)
        checkout = find_spm_checkout(identity)
        if not checkout:
            warnings.append(f"SPM checkout not found for '{identity}' — run `swift package resolve`")
            continue
        spdx, lic = read_license(checkout)
        results.append(entry(
            name    = display,
            version = pin["version"],
            url     = pin["url"],
            spdx    = spdx,
            license_text = lic,
            authors = "",   # SPM packages don't reliably embed author metadata
        ))

    # ── Rust / Cargo ───────────────────────────────────────────────────────
    cargo_versions = read_cargo_versions()
    for dep in RUST_DIRECT_DEPS:
        version = cargo_versions.get(dep)
        if not version:
            warnings.append(f"Rust dep '{dep}' not found in Cargo.lock")
            continue
        pkg_dir = find_rust_pkg_dir(dep, version)
        if not pkg_dir:
            warnings.append(f"Cargo registry dir not found for '{dep}-{version}' — run `cargo build`")
            continue
        spdx, lic = read_license(pkg_dir)
        meta      = read_cargo_toml_meta(pkg_dir)
        url       = RUST_URL_OVERRIDE.get(dep) or meta["repository"] or meta["homepage"]
        results.append(entry(
            name    = dep,
            version = version,
            url     = url,
            spdx    = spdx,
            license_text = lic,
            authors = meta["authors"],
        ))

    # ── Write ──────────────────────────────────────────────────────────────
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
        f.write("\n")

    for w in warnings:
        print(f"⚠️  {w}", file=sys.stderr)

    rel = OUTPUT.relative_to(REPO_ROOT)
    print(f"✓  {len(results)} entries written → {rel}")
    if warnings:
        print(f"   ({len(warnings)} warning(s) — some packages may be missing)")


if __name__ == "__main__":
    main()
