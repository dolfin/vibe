#!/usr/bin/env bash
set -euo pipefail

# Adapted document-icon generation block from generate-player-icons.sh
# Updated to use the new Vibe assets:
#   BACKGROUND_PNG=/mnt/data/vibe_background_1024_from_provided.png
#   FOREGROUND_PNG=/mnt/data/logo-fg.png
#
# This script keeps the original document-icon generation intent, but swaps
# in the new background and logo assets.

BACKGROUND_PNG="${BACKGROUND_PNG:-../../res/vibe_background_1024_from_provided.png}"
FOREGROUND_PNG="${FOREGROUND_PNG:-../../res/logo-fg.png}"
DOC_TEMPLATE_PNG="${DOC_TEMPLATE_PNG:-../../res/magic_hat_macos_background.jpeg}"
OUT_PNG="${OUT_PNG:-../../res/vibe_document_icon_from_script.png}"
OUT_SVG="${OUT_SVG:-../../res/vibe_document_icon_from_script.svg}"

python3 <<'PY'
from PIL import Image
import numpy as np
import base64
from pathlib import Path
import os

template = Image.open(os.environ["DOC_TEMPLATE_PNG"]).convert("RGBA")
bg = Image.open(os.environ["BACKGROUND_PNG"]).convert("RGBA").resize(template.size, Image.LANCZOS)
fg = Image.open(os.environ["FOREGROUND_PNG"]).convert("RGBA")

tpl_rgb = np.array(template.convert("RGB"))
doc_mask = ~((tpl_rgb[:,:,0] > 245) & (tpl_rgb[:,:,1] > 245) & (tpl_rgb[:,:,2] > 245))
mask_img = Image.fromarray((doc_mask * 255).astype("uint8"), mode="L")

base = Image.new("RGBA", template.size, (255,255,255,0))
base.paste(bg, (0,0), mask_img)

overlay = template.copy()
overlay.putalpha(90)
composite = Image.alpha_composite(base, overlay)

fg_rgb = np.array(fg.convert("RGB"))
# remove black background if present
fg_mask = ~((fg_rgb[:,:,0] < 20) & (fg_rgb[:,:,1] < 20) & (fg_rgb[:,:,2] < 20))
fg.putalpha(Image.fromarray((fg_mask * 255).astype("uint8"), mode="L"))

max_w = int(template.width * 0.78)
max_h = int(template.height * 0.72)
scale = min(max_w / fg.width, max_h / fg.height)
new_size = (int(fg.width * scale), int(fg.height * scale))
fg = fg.resize(new_size, Image.LANCZOS)
x = (template.width - new_size[0]) // 2
y = int(template.height * 0.18)

canvas = composite.copy()
canvas.alpha_composite(fg, (x, y))
canvas.save(os.environ["OUT_PNG"])

png_bytes = Path(os.environ["OUT_PNG"]).read_bytes()
b64 = base64.b64encode(png_bytes).decode("ascii")
svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{template.width}" height="{template.height}" viewBox="0 0 {template.width} {template.height}">
  <image href="data:image/png;base64,{b64}" x="0" y="0" width="{template.width}" height="{template.height}"/>
</svg>
'''
Path(os.environ["OUT_SVG"]).write_text(svg, encoding="utf-8")
print(os.environ["OUT_PNG"])
print(os.environ["OUT_SVG"])
PY
