#!/bin/bash
# Installs and starts fanierd as a root LaunchDaemon.
# Run via the menu bar app (admin prompt) or manually with sudo.
set -euo pipefail

LABEL="org.kamil.fannier.fanierd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

# Locate repository root (repo checkout) — build if needed
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -x ".build/release/fanierd" ] || [ ! -x ".build/release/fannier" ]; then
  echo "Building release binaries…" >&2
  swift build -c release --product fanierd >&2
  swift build -c release --product fannier >&2
fi

install -m 0755 .build/release/fanierd /usr/local/bin/fanierd

install -d -m 0755 /usr/local/bin
mkdir -p "/Users/${SUDO_USER:-$USER}/Library/Application Support/fannier"
chown "${SUDO_USER:-$USER}" "/Users/${SUDO_USER:-$USER}/Library/Application Support/fannier" || true

cat >"$PLIST" <<PLIST_XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/fanierd</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>/tmp/fannier.log</string>
    <key>StandardErrorPath</key><string>/tmp/fannier.log</string>
</dict>
</plist>
PLIST_XML

launchctl bootout system/${LABEL} 2>/dev/null || true
launchctl bootstrap system "${PLIST}"
launchctl kickstart -k system/${LABEL}

echo "fanierd installed (label ${LABEL})."
