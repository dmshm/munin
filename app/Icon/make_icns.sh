#!/usr/bin/env bash
# Turn Munin.png (1024 px, from make_icon.swift) into Munin.icns for the app bundle.
set -euo pipefail
cd "$(dirname "$0")"

set_dir="$(mktemp -d)/Munin.iconset"
mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
  sips -z $s $s Munin.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Munin.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Munin.icns
echo "Built $(pwd)/Munin.icns"
