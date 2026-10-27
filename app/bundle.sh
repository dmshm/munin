#!/usr/bin/env bash
# Build "Munin.app" next to this script. No Xcode project needed — SwiftPM
# builds the binary, this wraps it in the bundle macOS expects for a GUI app.
#
#   app/bundle.sh             this Mac's architecture, for trying things out
#   app/bundle.sh --release   Apple silicon and Intel in one binary, zipped into dist/
set -euo pipefail
cd "$(dirname "$0")"

version="0.1.0"
release=0
[ "${1:-}" = "--release" ] && release=1

if [ "$release" = 1 ]; then
  flags=(-c release --arch arm64 --arch x86_64)
else
  flags=(-c release)
fi
swift build "${flags[@]}"
bin="$(swift build "${flags[@]}" --show-bin-path)"

app="Munin.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Munin" "$app/Contents/MacOS/"
# Resources sit where Bundle.main finds them: SwiftPM's Bundle.module would look for
# its bundle at the app's top level, which breaks the signature.
cp Sources/Munin/Resources/watchtower.json Icon/Munin.icns "$app/Contents/Resources/"
# Set Up Game Assets runs these.
cp ../tools/setup_assets.sh ../tools/extract_meshes.py "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Munin</string>
  <key>CFBundleDisplayName</key><string>Munin</string>
  <key>CFBundleIdentifier</key><string>io.github.dmshm.munin</string>
  <key>CFBundleExecutable</key><string>Munin</string>
  <key>CFBundleIconFile</key><string>Munin</string>
  <key>NSHumanReadableCopyright</key><string>MIT licence. Not affiliated with Iron Gate or Coffee Stain.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad hoc: enough for Apple silicon to run it. Without a Developer ID it is not
# notarized, so a downloaded copy needs Open Anyway once (see the README).
codesign --force --sign - "$app" >/dev/null
echo "Built $(pwd)/$app"

if [ "$release" = 1 ]; then
  mkdir -p dist
  zip="dist/Munin-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  echo "Packed $(pwd)/$zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
fi
