#!/bin/bash
# Dev install: builds release binaries from this checkout, installs fanierd +
# fanctl into /usr/local/bin and (re)bootstraps the root LaunchDaemon.
# Run via the menu bar app (admin prompt) or manually with sudo.
# The packaged .app uses scripts/install-daemon.sh instead (no build step).
set -euo pipefail

LABEL="org.kamil.fannier.fanierd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building release binaries…" >&2
swift build -c release >&2
BIN_DIR="$(swift build -c release --show-bin-path)"

install -d -m 0755 /usr/local/bin
install -m 0755 "$BIN_DIR/fanierd" /usr/local/bin/fanierd
if [ -x "$BIN_DIR/fanctl" ]; then
  install -m 0755 "$BIN_DIR/fanctl" /usr/local/bin/fanctl
fi

# shared config dir for the daemon (runs as root) and the GUI (reads it)
install -d -m 0755 "/Library/Application Support/fannier"

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
    <key>StandardOutPath</key><string>/var/log/fannier.log</string>
    <key>StandardErrorPath</key><string>/var/log/fannier.log</string>
</dict>
</plist>
PLIST_XML

launchctl bootout system/${LABEL} 2>/dev/null || true
launchctl bootstrap system "${PLIST}"
launchctl kickstart -k system/${LABEL}

echo "fanierd installed (label ${LABEL}); profiles in /Library/Application Support/fannier"
