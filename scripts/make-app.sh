#!/bin/bash
# Packages fannier.app (menu bar app + bundled fanierd/fanctl + privileged
# installer) and a drag-to-Applications DMG. Ad-hoc signed (local use).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="0.2.1"
APP_ID="org.kamil.fannier.app"
BUNDLE_NAME="fannier"

echo "==> Building release binaries (swift build -c release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
echo "    bin dir: $BIN_DIR"

BUILD="$ROOT/build"
APP="$BUILD/$BUNDLE_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 0755 "$BIN_DIR/fannier" "$APP/Contents/MacOS/fannier"
install -m 0755 "$BIN_DIR/fanierd" "$APP/Contents/Resources/fanierd"
install -m 0755 "$BIN_DIR/fanctl" "$APP/Contents/Resources/fanctl"
install -m 0755 "$ROOT/scripts/install-daemon.sh" \
    "$APP/Contents/Resources/install-daemon.sh"

cat > "$APP/Contents/Info.plist" <<PLIST_XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>fannier</string>
    <key>CFBundleDisplayName</key><string>fannier</string>
    <key>CFBundleIdentifier</key><string>${APP_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>fannier</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>fannier</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_XML
printf 'APPL????' > "$APP/Contents/PkgInfo"

# icon (best effort — generic icon if rendering fails)
ICONSET="$BUILD/fannier.iconset"
rm -rf "$ICONSET"
if swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/fannier.icns" 2>/dev/null; then
  echo "    icon: fannier.icns"
else
  echo "    icon generation skipped (generic icon)"
fi
rm -rf "$ICONSET"

# ad-hoc signature — Apple Silicon requires at least this to execute
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature: ad-hoc OK"

# DMG (drag to /Applications)
DMG="$BUILD/fannier-${VERSION}.dmg"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<TXT
fannier ${VERSION} — fan control for Apple Silicon Macs

1. Drag fannier.app into Applications.
2. Launch fannier (menu bar fan icon appears).
3. Choose "Install / restart fanierd (sudo)…" once — installs the
   privileged helper (admin password prompt).

Temps/fans are readable without privileges; controlling fan speed
requires the installed helper (root LaunchDaemon).
TXT
hdiutil create -volname "fannier ${VERSION}" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> Done"
echo "App: $APP"
echo "DMG: $DMG"
