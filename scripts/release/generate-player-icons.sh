#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_svg="$repo_root/res/magic_hat_macos.svg"
background_svg="$repo_root/res/magic_hat_macos_background.svg"
foreground_png="$repo_root/res/magic_hat_macos_foreground.png"

app_assets_dir="$repo_root/player/macos/App/Assets.xcassets"
app_iconset_dir="$app_assets_dir/AppIcon.appiconset"
document_icon_path="$repo_root/player/macos/App/VibeAppDocument.icns"
tauri_icons_dir="$repo_root/player/src-tauri/icons"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

render_png() {
    local size="$1"
    local output_path="$2"
    rsvg-convert --keep-aspect-ratio --width "$size" --height "$size" "$source_svg" > "$output_path"
}

require_tool rsvg-convert
require_tool iconutil
require_tool magick

if [[ ! -f "$source_svg" ]]; then
  echo "Source icon not found: $source_svg" >&2
  exit 1
fi

if [[ ! -f "$background_svg" ]]; then
  echo "Background source not found: $background_svg" >&2
  exit 1
fi

if [[ ! -f "$foreground_png" ]]; then
  echo "Foreground source not found: $foreground_png" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$app_iconset_dir" "$tauri_icons_dir"

cat > "$app_assets_dir/Contents.json" <<'EOF'
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
EOF

cat > "$app_iconset_dir/Contents.json" <<'EOF'
{
  "images": [
    {
      "filename": "app-icon-16.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "16x16"
    },
    {
      "filename": "app-icon-32.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "16x16"
    },
    {
      "filename": "app-icon-32.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "32x32"
    },
    {
      "filename": "app-icon-64.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "32x32"
    },
    {
      "filename": "app-icon-128.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "128x128"
    },
    {
      "filename": "app-icon-256.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "128x128"
    },
    {
      "filename": "app-icon-256.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "256x256"
    },
    {
      "filename": "app-icon-512.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "256x256"
    },
    {
      "filename": "app-icon-512.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "512x512"
    },
    {
      "filename": "app-icon-1024.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "512x512"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
EOF

for size in 16 32 48 64 128 256 512 1024; do
  render_png "$size" "$tmp_dir/app-$size.png"
done

cp "$tmp_dir/app-16.png" "$app_iconset_dir/app-icon-16.png"
cp "$tmp_dir/app-32.png" "$app_iconset_dir/app-icon-32.png"
cp "$tmp_dir/app-64.png" "$app_iconset_dir/app-icon-64.png"
cp "$tmp_dir/app-128.png" "$app_iconset_dir/app-icon-128.png"
cp "$tmp_dir/app-256.png" "$app_iconset_dir/app-icon-256.png"
cp "$tmp_dir/app-512.png" "$app_iconset_dir/app-icon-512.png"
cp "$tmp_dir/app-1024.png" "$app_iconset_dir/app-icon-1024.png"

document_background="$tmp_dir/document-background.png"
rsvg-convert --width 1024 --height 1024 "$background_svg" > "$document_background"

document_page_art_raw="$tmp_dir/document-page-art-raw.png"
rsvg-convert --width 760 --height 760 "$source_svg" > "$document_page_art_raw"

document_page_art_mask="$tmp_dir/document-page-art-mask.png"
magick \
  -size 760x760 xc:black \
  -fill white -draw "roundrectangle 144,168 664,676 180,180" \
  -blur 0x56 \
  "$document_page_art_mask"

document_page_art="$tmp_dir/document-page-art.png"
magick \
  "$document_page_art_raw" \
  "$document_page_art_mask" -alpha off -compose copyopacity -composite \
  "$document_page_art"

document_background_shadowed="$tmp_dir/document-background-shadowed.png"
magick \
  "$document_background" \
  \( +clone -background 'rgba(0,0,0,0.16)' -shadow 0x24+0+14 \) \
  +swap -background none -layers merge +repage \
  "$document_background_shadowed"

document_content="$tmp_dir/document-content.png"
magick \
  -size 1024x1024 xc:none \
  "$document_page_art" -geometry +156+332 -compose over -composite \
  "$document_content"

document_mask="$tmp_dir/document-mask.png"
magick "$document_background" -alpha extract "$document_mask"

document_fold_exclusion="$tmp_dir/document-fold-exclusion.png"
magick \
  -size 1024x1024 xc:white \
  -fill black -draw "path 'M 614,126 L 866,378 L 680,378 C 643.549,378 614,348.451 614,312 Z'" \
  "$document_fold_exclusion"

document_content_mask="$tmp_dir/document-content-mask.png"
magick "$document_mask" "$document_fold_exclusion" -compose multiply -composite "$document_content_mask"

document_content_alpha="$tmp_dir/document-content-alpha.png"
magick "$document_content" -alpha extract "$document_content_alpha"

document_content_alpha_masked="$tmp_dir/document-content-alpha-masked.png"
magick "$document_content_alpha" "$document_content_mask" -compose multiply -composite "$document_content_alpha_masked"

document_content_masked="$tmp_dir/document-content-masked.png"
magick \
  "$document_content" \
  "$document_content_alpha_masked" -alpha off -compose copyopacity -composite \
  "$document_content_masked"

document_1024="$tmp_dir/document-1024.png"
magick \
  "$document_background_shadowed" \
  "$document_content_masked" -compose over -composite \
  "$document_1024"

document_iconset_dir="$tmp_dir/VibeAppDocument.iconset"
mkdir -p "$document_iconset_dir"

for size in 16 32 128 256 512; do
  magick "$document_1024" -resize "${size}x${size}" "$document_iconset_dir/icon_${size}x${size}.png"
  retina_size=$((size * 2))
  magick "$document_1024" -resize "${retina_size}x${retina_size}" "$document_iconset_dir/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$document_iconset_dir" -o "$document_icon_path"

tauri_iconset_dir="$tmp_dir/tauri.iconset"
mkdir -p "$tauri_iconset_dir"
for size in 16 32 128 256 512; do
  cp "$tmp_dir/app-$size.png" "$tauri_iconset_dir/icon_${size}x${size}.png"
  retina_size=$((size * 2))
  cp "$tmp_dir/app-$retina_size.png" "$tauri_iconset_dir/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$tauri_iconset_dir" -o "$tauri_icons_dir/icon.icns"
cp "$tmp_dir/app-32.png" "$tauri_icons_dir/32x32.png"
cp "$tmp_dir/app-128.png" "$tauri_icons_dir/128x128.png"
cp "$tmp_dir/app-256.png" "$tauri_icons_dir/128x128@2x.png"
cp "$tmp_dir/app-512.png" "$tauri_icons_dir/icon.png"
magick "$tmp_dir/app-256.png" "$tmp_dir/app-128.png" "$tmp_dir/app-64.png" "$tmp_dir/app-48.png" "$tmp_dir/app-32.png" "$tmp_dir/app-16.png" "$tauri_icons_dir/icon.ico"

echo "Generated macOS and Tauri icon assets from $source_svg"
