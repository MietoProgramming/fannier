#!/bin/bash
# install-daemon.sh (app-bundle variant)
# Called with admin privileges by the menu bar app: installs the prebuilt
# fanierd + fanctl from this bundle and bootstraps the root LaunchDaemon.
# No building happens here — binaries ship inside the .app.
set -euo pipefail

LABEL="org.kamil.fannier.fanierd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ -x "$DIR/fanierd" ] || { echo "fanierd binary missing next to this script" >&2; exit 1; }

install -d -m 0755 /usr/local/bin
install -m 0755 "$DIR/fanierd" /usr/local/bin/fanierd
if [ -x "$DIR/fanctl" ]; then
  install -m 0755 "$DIR/fanctl" /usr/local/bin/fanctl
fi

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
