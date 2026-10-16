# fannier

Menu-bar fan control for Apple Silicon Macs with **temperature-driven, switchable profiles**.

Monitors CPU/GPU die temperatures and fans via the SMC, and (through a tiny
root daemon) forces fan targets according to the active profile curve.
Developed and verified on MacBook Pro M5 Max / macOS 27 — the same SMC write
path (`F<id>md` mode + `F<id>Tg` float target, no `Ftst` unlock) that
exelban/stats uses on M5+ machines.

## ⚠️ Safety

Third-party fan control bypasses Apple's own thermal governor **by design** —
that is the point (and also why fan speeds can be set "wrong"). Mitigations in
this project:

- fanierd **restores macOS automatic control on SIGTERM/SIGINT/exit**,
- profiles are clamped to the hardware min/max RPM read from the SMC,
- a top "emergency" temperature (per profile) forces 100% RPM,
- when fanierd is not running nothing is written — the SMC returns to the
  macOS-controlled state on its own (there is no persistence of forced mode
  once nothing holds it… but fanierd *is* KeepAlive'd, so check
  `launchctl list | grep fanier` if you ever suspect a stuck manual mode).

**Do not** set emergency temps above ~100 °C or remove the emergency branch.

## Layout

```
Sources/FanSMC/        SMC user-client: reads (any user), writes (root)
Sources/FanCore/       profiles, engine (pure), controller, daemon protocol
Sources/Fannierd/      root LaunchDaemon: unix-socket JSON API + apply loop
Sources/FannierApp/    menu bar app (temps in the bar, profiles in the menu)
Sources/fanctl/        small CLI (status / use / manual / auto / read)
Tests/FanCoreTests/    curve/hysteresis/clamping unit tests
scripts/make-app.sh          package fannier.app + fannier-0.1.0.dmg (ad-hoc signed)
scripts/install-daemon.sh    app-bundle installer (no build): copies fanierd/fanctl,
                             bootstraps the root LaunchDaemon
scripts/install-launchd.sh   dev install: builds release, installs, bootstraps
scripts/make-icon.swift      renders the app .icns (fan glyph)
```

Config lives in `/Library/Application Support/fannier/profiles.json`
(daemon-owned; hand-editing needs `sudo`). Built-ins are re-merged on load,
so deleting a built-in profile just restores it. `state.json` remembers the
last active profile across reboots. Before the daemon is first installed the
GUI falls back to `~/Library/Application Support/fannier`.

## Install as an app (recommended)

```sh
./scripts/make-app.sh     # → build/fannier.app + build/fannier-0.1.0.dmg
open build/fannier.app    # or drag from the DMG into /Applications
```

First run: the menu bar fan icon appears (no Dock icon). Choose
**“Install / restart fanierd (sudo)…”** once — it prompts for the admin
password, copies the bundled `fanierd` + `fanctl` into `/usr/local/bin`,
and bootstraps the KeepAlive root LaunchDaemon. Profile switching works
immediately afterwards.

The app is **ad-hoc signed** (fine for local use). Distributing it to other
Macs requires a Developer ID signature + notarization.

The status bar shows the hottest CPU/GPU reading; the menu lists profile
radio buttons (active one checked), current fan RPMs/min/max, and the
install/restart item.

## Build & run from source (dev)

```sh
swift build && swift test
./scripts/install-launchd.sh   # one-time privileged install (builds first)
.build/debug/fannier           # run the menu bar app
```

CLI (`fanctl`) for quick checks and scripting:

```sh
.build/debug/fanctl status        # temps + fans (daemon first, else direct SMC)
.build/debug/fanctl read Tp0U     # raw SMC key
.build/debug/fanctl use Performance    # via fanierd
sudo .build/debug/fanctl manual 0 4000 # forced RPM (root + fanierd)
.build/debug/fanctl auto               # back to macOS control
```

## Protocol (fanierd)

JSON envelope `{"request": ...}` over `/var/run/fannier.sock`, one line in,
one line out. Requests:

| request | effect |
|---|---|
| `{"request":{"status":{}}}` | fans/temps/active profile |
| `{"request":{"profiles":{}}}` | profile names |
| `{"request":{"useProfile":"Performance"}}` | switch & apply |
| `{"request":{"setManual":{"fan":0,"rpm":3500}}}` | forced RPM until resume |
| `{"request":{"resumeAutomatic":{}}}` | back to macOS control |

(encoding via `DaemonRequest` Codable enum)

## References

- exelban/stats — `SMC/smc.swift` (MIT): Apple Silicon fan writes, M5+ path
- narugit/smctemp (GPL-2.0): M1–M5 sensor key sets
- beltex/SMCKit (MIT): canonical 80-byte `SMCParamStruct`
