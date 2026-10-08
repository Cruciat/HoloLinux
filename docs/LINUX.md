# Holo on Linux

**Tap your desk. Your Linux laptop responds.**

This is a headless port of Holo for Linux laptops. It reuses the macOS
app's signal processing and classifier (`HoloCore`) unchanged and replaces
the macOS layers:

| macOS app | Linux port |
|---|---|
| SwiftUI window | `holo` terminal commands for calibration, evaluation, actions, diagnostics |
| Desk view listening while the window is open | `holo.service`, a systemd user service |
| AVAudioEngine | ALSA capture (through PipeWire's ALSA plugin on modern desktops) |
| Core Audio built-in route check | PipeWire node properties (`wpctl`) or `/proc/asound` for raw devices |
| Desk-map highlight | optional desktop notification per accepted tap |
| Security-scoped bookmarks | file paths and desktop entry ids |

Like the original, Holo on Linux is a research prototype. The same rule
applies: no accuracy claim without a 60-tap evaluation on your own laptop,
desk, and position.

## Requirements

- An x86-64 laptop with a built-in microphone.
- PipeWire + WirePlumber (the default on Debian 13, Ubuntu, Fedora). Plain
  ALSA works too, without the automatic built-in-microphone check.
- For the `.deb`: Debian 13 (trixie). Elsewhere, build from source.

## Install

### Debian 13

```sh
sudo apt install ./holo_0.1.0-1_amd64.deb
```

Recommended packages (installed automatically by `apt` unless you disable
recommends): `pipewire-bin`, `wireplumber`, `libglib2.0-bin`, `xdg-utils`,
`wl-clipboard`, `sound-theme-freedesktop`. Optional: `espeak-ng` for spoken
text, `gnome-screenshot` for the screenshot actions.

### From source

Install a Swift toolchain (5.9 or newer; from swift.org, `swiftly`, or your
distribution) and the ALSA headers (`libasound2-dev` / `alsa-lib-devel`),
then:

```sh
scripts/linux/install.sh          # installs ~/.local/bin/holo and the user service
scripts/linux/build-deb.sh        # or build dist/holo_<version>_<arch>.deb
```

## Quick start

```sh
holo check          # is the internal microphone selected? which helper tools exist?
holo monitor        # live level meter; tap the desk and watch taps being detected
holo calibrate      # 10 taps in each of the 4 zones, then review and save
holo evaluate       # 15 new taps per zone; reports accuracy, latency, confusion matrix
holo actions set lr url https://calendar.google.com
holo actions set rr shell 'playerctl play-pause'
systemctl --user enable --now holo
journalctl --user -u holo -f      # watch it work
```

Zones are named from your seat, like in the original:

```text
                  display side
Left Rear  (lr) ┌─────────────┐ Right Rear  (rr)
                │   laptop    │
Left Front (lf) └─────────────┘ Right Front (rf)
                  keyboard side
```

Put the laptop where it will stay before calibrating. Moving or rotating it
changes the acoustic path and invalidates the profile.

## Commands

| Command | What it does |
|---|---|
| `holo check` | Microphone route (built-in / external / unknown), capture settings, helper tools, profiles, service state |
| `holo monitor` | Input level and every detected tap with its quality and predicted zone. No actions. `--save-wav` keeps raw 90 ms windows |
| `holo calibrate` | Guided calibration: arms each zone automatically, rejects weak/noisy/clipped taps, undo (`u`), redo zone (`r`), pause (`p`). After 40 taps it shows the leave-one-out agreement per zone and offers to redo the weakest zone or record rejection examples (talking, typing, laptop touches, room noise). `--recalibrate` replaces the active profile and keeps its actions |
| `holo evaluate` | The held-out accuracy test: Enter arms each zone, 15 taps per zone. Rejected taps count as wrong. Saves JSON + CSV and prints the confusion matrix. Exit status 0 only if ≥ 80 % accuracy and < 200 ms median response |
| `holo report` | The newest saved accuracy report (`--json` for the raw report) |
| `holo compare` | Three taps per zone with passive, active, and hybrid sensing; the best becomes the default for the next calibration |
| `holo actions` | `list`, `set ZONE KIND [VALUE]`, `clear ZONE`, `test ZONE` |
| `holo profiles` | `list`, `use`, `show`, `rename`, `delete --yes` |
| `holo config` | `notifications on/off`, `device DEV` |
| `holo run` | The listener in the foreground (what the service runs) |
| `holo pause` / `holo resume` | Pause the service and release the microphone |
| `holo status` | Is the service running, paused, which profile |

Every command has `--help`.

### Actions

| Kind | Value | Runs |
|---|---|---|
| `visual` | | nothing (log line and, if enabled, a notification) |
| `sound` | freedesktop sound name or file | `pw-play` / `paplay` / `canberra-gtk-play` |
| `copy` | text | `wl-copy` (Wayland) or `xclip` / `xsel` (X11) |
| `speak` | text | `spd-say` or `espeak-ng` |
| `url` | http(s) address | `xdg-open` |
| `app` | desktop id (`firefox`, `org.gnome.Nautilus`) or a command | `gtk-launch` / `gio launch` |
| `open` | file or folder path | `xdg-open` |
| `shell` | command | `bash -lc COMMAND` |
| `screenshot`, `screenshot-area` | | `gnome-screenshot -c`, or the desktop portal via `holo-screenshot-portal`, `spectacle`, `grim`, `maim` |

Actions run only for accepted taps while the service is listening. They
never run during `calibrate`, `evaluate`, `compare`, or `monitor`: those
sessions take a lock that makes the service release the microphone and stop
dispatching until they end — the same rule as the macOS app, where only the
Desk view runs actions. Shell commands run on every accepted tap, so make
them safe to repeat. macOS Shortcuts have no Linux equivalent; use `shell`.

## The microphone

Holo requires the laptop's built-in microphone, like the original, because
a profile is only valid for the signal path it was calibrated on:

- With PipeWire, Holo inspects the default source with `wpctl`. PCI and
  platform devices (the laptop's audio controller) count as built-in; USB
  and Bluetooth devices are refused unless you pass `--allow-external-input`.
- Virtual or filtered sources (EasyEffects, noise suppression, echo
  cancellation) are reported as *unknown* and allowed with a warning. They
  usually suppress exactly the short impulses Holo listens for, so select
  the raw internal microphone instead.
- If the microphone exposes two channels (many laptops have a two-element
  digital microphone array), Holo captures both and uses their level and
  timing difference as features. `--channels 1` forces mono.
- `--device plughw:0,6` (see `arecord -l`) captures a raw ALSA device
  directly, bypassing PipeWire. Holo checks `/proc/asound` to refuse USB
  cards. A device held exclusively by PipeWire may report "busy".

The service re-checks the route every five seconds. When the default input
changes to an external device, it stops listening (with a notification)
and resumes automatically once the internal microphone is back.

Active and hybrid sensing play a quiet 15.5–21 kHz chirp through the
default output and therefore also require the built-in speakers. Passive
sensing never plays anything.

## The background service

```sh
systemctl --user enable --now holo    # start now and at every graphical login
systemctl --user restart holo
journalctl --user -u holo -f
```

The service waits for a profile if none exists yet, reloads within a second
when you change profiles or actions, retries when the microphone is
unavailable, and logs every accepted or rejected tap with its confidence
and response time.

GNOME passes `WAYLAND_DISPLAY` and `DISPLAY` to user services. On other
desktops, if clipboard or screenshot actions report that no graphical
session is visible, run once after login:

```sh
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP
```

Notifications use the standard `org.freedesktop.Notifications` service.
Turn them off with `holo config notifications off`, or per app in GNOME
Settings › Notifications › Holo.

## Files and privacy

Audio is processed locally and never leaves the computer. Raw audio is
discarded after feature extraction unless you run `holo monitor --save-wav`.

```text
~/.local/share/Holo/Profiles/         feature-only profile JSON (same format as macOS)
~/.local/share/Holo/Evaluations/      JSON and CSV accuracy reports
~/.local/share/Holo/approach-comparison.json
~/.local/share/Holo/DebugCaptures/    only with --save-wav
~/.config/holo/config.json            active profile, notifications, capture settings per profile
$XDG_RUNTIME_DIR/holo/                locks and the pause flag
```

`HOLO_DATA_DIR`, `HOLO_CONFIG_DIR`, and `HOLO_RUNTIME_DIR` override these
locations (useful for experiments).

Profiles from a Mac are readable but not useful: they describe a different
microphone, chassis, and desk.

## Development

```sh
swift build
swift test                      # HoloCore, replay, and Linux tests
swift build -c release --static-swift-stdlib --product holo
```

On Linux, `Package.swift` adds four targets: `CAlsa` (system library
module for libasound), `HoloLinux` (capture, route inspection, guided
session controllers, service, actions), `HoloLinuxCLI` (the `holo`
executable), and `HoloLinuxTests`. They are compiled only on Linux, so the
macOS build is unaffected.

The guided session controllers are pure state machines that mirror the
timing of the macOS `AppModel` (one-second arm delay, two-second zone
transition, 0.4 s between accepted taps, undo, redo, rejection examples),
so they are tested without audio. The service test plays synthetic taps
through the real detector and classifier and runs real shell actions.

## Troubleshooting

| Symptom | What to do |
|---|---|
| `holo monitor` shows taps as *Weak* | Raise the input volume in Settings › Sound › Input (or `alsamixer`, capture controls), then calibrate again |
| Taps show as *Clipped* | Lower the input volume, or tap more lightly |
| Nothing is detected, the meter barely moves | Check that the internal microphone is the selected input and not muted (`holo check`, `wpctl status`) |
| "virtual or filtered source" warning | Disable noise suppression / EasyEffects for the microphone, or select the raw internal microphone |
| "Device or resource busy" with `--device plughw:…` | PipeWire holds the device; use the default device instead |
| Accuracy drops after a few days | The laptop moved or the room changed: `holo calibrate --recalibrate` |
| No notifications from the service | `holo config notifications on`; check GNOME Settings › Notifications › Holo |
| Clipboard or screenshot actions fail from the service only | See the `import-environment` note above |
| `holo` prints "Another Holo session is already using the microphone" | Finish the other `calibrate`/`evaluate`/`compare`/`monitor` first |

## Known limitations

- No graphical interface; calibration happens in a terminal.
- Accuracy depends on the laptop, desk, and room exactly as on macOS and
  must be measured with `holo evaluate`.
- The screenshot actions on GNOME need `gnome-screenshot` or the portal
  helper (`python3-gi`); the portal may ask for confirmation.
- Built against glibc 2.38 and ICU 76: the `.deb` targets Debian 13. Other
  distributions should build from source.
