#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
default_app_path="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/*/Vibe.app' -maxdepth 8 | head -n 1)"

if [[ -z "$default_app_path" || ! -d "$default_app_path" ]]; then
  echo "Could not find a built Vibe.app in Xcode DerivedData." >&2
  echo "Build the app first with: make build" >&2
  exit 1
fi

if [[ "$#" -gt 0 ]]; then
  files=("$@")
else
  shopt -s nullglob
  files=("$repo_root"/*.vibeapp)
  shopt -u nullglob
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No .vibeapp files found to refresh." >&2
  exit 1
fi

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

"$lsregister" -f "$default_app_path"

for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Skipping missing file: $file" >&2
    continue
  fi

  tmp="${file}.tmp-refresh"
  cp "$file" "$tmp"
  mv "$tmp" "$file"
  mdimport "$file"

  echo "--- $file"
  mdls -name kMDItemContentType -name kMDItemKind "$file"
done
