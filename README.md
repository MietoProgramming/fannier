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
scripts/install-launchd.sh   build release, install /usr/local/bin/fanierd,
                             bootstrap LaunchDaemon with KeepAlive
```

Config lives in `~/Library/Application Support/fannier/profiles.json`
(built-ins are re-merged on load, so deleting a built-in profile just
restores it). `state.json` remembers the last active profile across reboots.

## Build & install

```sh
swift build && swift test
# one-time privileged install (prompts for admin password):
./scripts/install-launchd.sh
```

Then launch the menu bar app: `.build/debug/fannier` (or make an .app bundle
later). The status bar shows the hottest CPU/GPU reading; the menu lists
profile radio buttons (active one checked), current fan RPMs/min/max, and an
"Install / restart fanierd (sudo)" item when the daemon is missing.

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
