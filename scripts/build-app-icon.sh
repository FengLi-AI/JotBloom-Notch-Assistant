#!/bin/bash
# Convert the approved artwork without redrawing or changing its design.
set -euo pipefail
export COPYFILE_DISABLE=1
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_image="$project_dir/branding/AppIcon-source.png"
icon_work="$(mktemp -d /tmp/jotbloom-icon.XXXXXX)"
iconset="$icon_work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$project_dir/JotBloom/Resources"
iconutil -c icns "$iconset" -o "$project_dir/JotBloom/Resources/AppIcon.icns"
echo "AppIcon.icns generated; source preserved. Iconset: $iconset"
