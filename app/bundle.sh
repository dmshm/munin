#!/usr/bin/env bash
# Build "Munin.app" next to this script. No Xcode project needed — SwiftPM
# builds the binary, this wraps it in the bundle macOS expects for a GUI app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
bin="$(swift build -c release --show-bin-path)"

app="Munin.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Munin" "$app/Contents/MacOS/"
# SwiftPM's resource bundle (Bundle.module) is looked up next to the executable.
cp -R "$bin/Munin_Munin.bundle" "$app/Contents/Resources/"
cp Icon/Munin.icns "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "Built $(pwd)/$app"
