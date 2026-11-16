#!/bin/bash
# Packages fannier.app (menu bar app + bundled fanierd/fanctl + privileged
# installer), a ZIP and a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${FANNIER_VERSION:-0.3.1}"
APP_ID="org.kamil.fannier.app"
BUNDLE_NAME="fannier"
SIGNING_IDENTITY="${FANNIER_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${FANNIER_NOTARY_PROFILE:-}"
NOTARIZE="${FANNIER_NOTARIZE:-0}"

if [[ "$NOTARIZE" != "0" && "$NOTARIZE" != "1" ]]; then
  echo "FANNIER_NOTARIZE must be 0 or 1." >&2
  exit 2
fi
if [[ "$NOTARIZE" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "FANNIER_NOTARIZE=1 requires FANNIER_SIGNING_IDENTITY with a Developer ID Application identity." >&2
  exit 2
fi
if [[ "$NOTARIZE" == "1" && -z "$NOTARY_PROFILE" ]]; then
  echo "FANNIER_NOTARIZE=1 requires FANNIER_NOTARY_PROFILE from notarytool keychain credentials." >&2
  exit 2
fi

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

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  # Local use: preserve the repository's current ad-hoc signing behavior.
  codesign --force --deep --sign - "$APP"
  echo "    signature: ad-hoc"
else
  # Sign executable code from the inside out with Hardened Runtime for direct distribution.
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
      "$APP/Contents/MacOS/fannier"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
      "$APP/Contents/Resources/fanierd"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
      "$APP/Contents/Resources/fanctl"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
  echo "    signature: Developer ID identity applied"
fi
codesign --verify --deep --strict "$APP" && echo "    signature: verified"

if [[ "$NOTARIZE" == "1" ]]; then
  PACKAGE_SECURITY_STATUS="Developer ID signed and notarized"
elif [[ "$SIGNING_IDENTITY" == "-" ]]; then
  PACKAGE_SECURITY_STATUS="ad-hoc signed; not notarized"
else
  PACKAGE_SECURITY_STATUS="Developer ID signed; not notarized"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  UPLOAD_ZIP="$BUILD/fannier-notary-upload.zip"
  rm -f "$UPLOAD_ZIP"
  ditto -c -k --keepParent "$APP" "$UPLOAD_ZIP"
  xcrun notarytool submit "$UPLOAD_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$UPLOAD_ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# DMG (drag to /Applications)
DMG="$BUILD/fannier-${VERSION}.dmg"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/docs/hardware-compatibility.md" "$STAGE/hardware-compatibility.md"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<TXT
fannier ${VERSION} — fan control for Apple Silicon Macs

Package security: ${PACKAGE_SECURITY_STATUS}.

1. Drag fannier.app into Applications.
2. Launch fannier (menu bar fan icon appears).
3. Choose "Install / restart fanierd (sudo)…" once — installs the
   privileged helper (admin password prompt).

Temps/fans are readable without privileges; controlling fan speed
requires the installed helper (root LaunchDaemon).

Fan-target writes have been validated on MacBook Pro M5 Max (Mac17,7),
macOS 27.0.1. Other Mac models and macOS versions remain unvalidated.
Use Hardware diagnostics… in the menu or fanctl diagnostics for a read-only
report; detected SMC keys do not prove that a write will succeed.
TXT
hdiutil create -volname "fannier ${VERSION}" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

if [[ "$NOTARIZE" == "1" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

ZIP="$BUILD/$BUNDLE_NAME-${VERSION}.zip"
ZIP_STAGE="$BUILD/$BUNDLE_NAME-${VERSION}"
rm -rf "$ZIP_STAGE" "$ZIP"
mkdir -p "$ZIP_STAGE"
cp -R "$APP" "$ZIP_STAGE/"
cp "$ROOT/LICENSE" "$ZIP_STAGE/LICENSE"
cp "$ROOT/README.md" "$ZIP_STAGE/README.md"
cp "$ROOT/docs/hardware-compatibility.md" "$ZIP_STAGE/hardware-compatibility.md"
ditto -c -k --keepParent "$ZIP_STAGE" "$ZIP"

echo "==> Done"
echo "App: $APP"
echo "DMG: $DMG"
echo "ZIP: $ZIP"
