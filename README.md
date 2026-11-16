# fannier

Menu-bar fan control for Apple Silicon Macs with **temperature-driven, switchable profiles**.

Monitors CPU/GPU die temperatures and fans via the SMC, and (through a tiny
root daemon) forces fan targets according to the active profile curve.
Temperature reads and fan-target writes have been validated on MacBook Pro M5
Max (`Mac17,7`) / macOS 27.0.1. Other Mac models and macOS versions remain
unvalidated; run the read-only hardware report before considering control.

## ⚠️ Safety

Third-party fan control bypasses Apple's own thermal governor **by design** —
that is the point (and also why fan speeds can be set "wrong"). Mitigations in
this project:

- fanierd **restores macOS automatic control on SIGTERM/SIGINT/exit**,
- profiles are clamped to the hardware min/max RPM read from the SMC,
- a top "emergency" temperature (per profile) forces 100% RPM,
- fanierd **reads back and re-asserts the target** — a 1 s control tick and
  heartbeat (~2 s, `--heartbeat` to tune) re-writes manual mode and RPM when needed.
  It also reasserts immediately when it reads a fan back in automatic mode or
  when the SMC target differs from the requested RPM by more than 50 rpm. On
  Apple Silicon the SMC (`thermalmonitord`) flips fans back to automatic a few
  seconds after a single write, so a loop that only writes on temperature
  changes silently loses control; this is why fanierd is chatty on the SMC,
- failed target read-back is shown in the menu and `fanctl status`,
- when fanierd is not running nothing is written — the SMC returns to the
  macOS-controlled state on its own (there is no persistence of forced mode
  once nothing holds it… but fanierd *is* KeepAlive'd, so check
  `launchctl list | grep fanier` if you ever suspect a stuck manual mode).

**Do not** set emergency temps above ~100 °C or remove the emergency branch.

Install and use this software at your own risk. It can affect fan behavior and
may cause overheating, hardware damage, or other loss. You are responsible for
deciding whether it is suitable for your system and for monitoring it while in
use. The software is provided “as is,” without warranties of any kind. To the
fullest extent permitted by law, the author and contributors accept no
liability for hardware damage or other loss arising from installing or using
this software, or from being unable to use it.

## Layout

```
Sources/FanSMC/        SMC user-client: reads (any user), writes (root)
Sources/FanCore/       profiles, engine (pure), controller, diagnostics, protocol
Sources/Fannierd/      root LaunchDaemon: unix-socket JSON API + apply loop
Sources/FannierApp/    menu bar app (temps in the bar, profiles in the menu)
Sources/fanctl/        small CLI (status / use / manual / auto / read)
Tests/FanCoreTests/    curve/hysteresis/clamping unit tests
scripts/make-app.sh          package fannier.app + 0.3.1 DMG/ZIP (ad-hoc by default)
scripts/install-daemon.sh    app-bundle installer (no build): copies fanierd/fanctl,
                             bootstraps the root LaunchDaemon
scripts/install-launchd.sh   dev install: builds release, installs, bootstraps
scripts/make-icon.swift      renders the app .icns (fan glyph)
```

Config lives in `/Library/Application Support/fannier/profiles.json`
(daemon-owned; hand-editing needs `sudo`). Built-ins are re-merged on load,
so deleting a built-in profile just restores it. `state.json` remembers the
last active profile across reboots. macOS automatic mode is persisted separately
and remains selected after daemon restarts. Before the daemon is first installed the
GUI falls back to `~/Library/Application Support/fannier`.

## Install as an app (recommended)

```sh
./scripts/make-app.sh     # → build/fannier.app + build/fannier-0.3.1.dmg
open build/fannier.app    # or drag from the DMG into /Applications
```

First run: the menu bar fan icon appears (no Dock icon). Choose
**“Install / restart fanierd (sudo)…”** once — it prompts for the admin
password, copies the bundled `fanierd` + `fanctl` into `/usr/local/bin`,
and bootstraps the KeepAlive root LaunchDaemon. To start the app automatically,
choose **Settings…** (⌘,) → **Open at Login**. fannier will open when you log in,
including after restarting your Mac. The same switch is also available directly
in the menu. This is optional and stays off until you enable it.

Settings show the current macOS Login Item status. If approval is needed, click
**Open Login Items…** and allow fannier in System Settings. You can uncheck
**Open at Login** to cancel registration or turn automatic startup off. Run the
installed app from `/Applications` when configuring this option.

The app is ad-hoc signed by default for local use. Set
`FANNIER_SIGNING_IDENTITY` to a Developer ID Application identity to sign the
app and bundled executables with Hardened Runtime. Set `FANNIER_NOTARY_PROFILE`
to an existing `notarytool` Keychain profile and `FANNIER_NOTARIZE=1` to submit
and staple the app and DMG. These variables are required before notarization;
the build script stops before upload if they are missing.

The status bar shows the hottest CPU/GPU reading; the menu lists profiles,
current fan RPMs/min/max, macOS automatic control, **Hardware diagnostics…**,
the optional Login Item, and the daemon installer.

## Profiles — on-screen editor (no JSON required)

Menu bar icon → **Edit profiles…** (⌘E):

- **Profile list** on the left — built-ins plus your own; add / Duplicate /
  delete custom ones, the active profile is marked.
- **Temperature source** per profile: CPU / GPU / Max(CPU,GPU) or one exact
  sensor key (e.g. `Tp00`) — plus live readings for every listed sensor.
- **Curve editor** with any number of steps (°C → RPM): add, remove, sort;
  live chart with a marker for the current input temperature and a readout of
  the selected fan's resulting target.
- **Per-fan curves:** edit a shared default and optional overrides for
  individual fans. Fans without an override keep using the shared curve.
- **Advanced**: hysteresis (rewrite suppression) and emergency temperature
  (kept ≤ 100 °C by validation).

Saving goes through fanierd, which validates and clamps server-side; built-in
profiles can be edited in place ("saving keeps the name") or saved under a
new name, which creates a copy. `profiles.json` still lives in
`/Library/Application Support/fannier/` for power users, but the editor is
the primary interface.

## Build & run from source (dev)

```sh
swift build && swift test
./scripts/install-launchd.sh   # one-time privileged install (builds first)
.build/debug/fannier           # run the menu bar app
```

CLI (`fanctl`) for quick checks and scripting:

```sh
.build/debug/fanctl status        # temps + fans (daemon first, else direct SMC)
.build/debug/fanctl sensors       # per-key temps + hottest ("source") per group
.build/debug/fanctl diagnostics   # read-only model, SMC key and sensor report
.build/debug/fanctl diagnostics --json
.build/debug/fanctl read Tp0U     # raw SMC key
.build/debug/fanctl use Performance    # via fanierd
sudo .build/debug/fanctl manual 0 4000 # forced RPM (root + fanierd)
.build/debug/fanctl auto               # back to macOS control
```

## Protocol (fanierd)

JSON `{"cmd": …}` over `/var/run/fannier.sock`, one line in, one line out:

| request | effect |
|---|---|
| `{"cmd":"status"}` | fans/temps/active profile (temps carry the hottest key per group) |
| `{"cmd":"profiles"}` | profile names |
| `{"cmd":"profilesDetail"}` | full profile definitions (editor) |
| `{"cmd":"sensors"}` | per-sensor readings + hottest key per group |
| `{"cmd":"use","name":"Performance"}` | switch & apply |
| `{"cmd":"setProfile","profile":{…}}` | validate + save (upsert) a profile |
| `{"cmd":"delProfile","name":"…"}` | delete a custom profile |
| `{"cmd":"manual","fan":0,"rpm":3500}` | forced RPM until resume |
| `{"cmd":"auto"}` | back to macOS control |

(encoding via `DaemonRequest` Codable enum; `FANNIER_SOCKET` and
`FANNIER_PROFILES_DIR` env vars override socket/config paths for testing)

Profiles remain backward-compatible with the original `sensor` and `curve`
fields. `sensorKey` optionally selects one exact four-byte SMC key; `fanCurves`
stores per-fan overrides, each of which falls back to the shared `curve` when
absent. If the selected sensor is unavailable, the daemon restores macOS
automatic fan control and reports the missing source until it becomes readable.

See [hardware compatibility](docs/hardware-compatibility.md) for the tested
configuration and the distinction between a detected write-key layout and a
confirmed hardware write.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
