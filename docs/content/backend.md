---
title: Backend
group: Structure
summary: The anna Rust daemon — theme, hardware stats and audio (tuner, chromagram, metronome).
links: [widgets, audio-tools, ai, architecture, languages]
---

# Backend (`anna`)

The whole backend is a **single Rust daemon**, `anna` (folder `anna/`). One
daemon per session: if it finds the socket already served, it refuses to
start instead of stealing it. No more bash/python backend: the widgets talk
to `anna` through a **Unix socket** (`$XDG_RUNTIME_DIR/anna.sock`) in JSON,
one line per message.

## Exposed services

| Service | Command | Role |
| --- | --- | --- |
| theme | `set` / `mode` / `palette-color` / `reset` / `get` / `watch` | Accent + base16 palette, template rendering, live reload. Bursts (dragging, rainbow) are merged: only the latest state is applied. |
| hwstats | `hwstats_get` / `hwstats_watch` | Hardware stats (CPU/RAM/GPU/disks). |
| servers | `servers_watch` / `servers_list` / `servers_power` | The other devices of the Tailscale network (`tailscale status --json`, re-read at every sample), and the ssh stats of the online Linux ones (with `name`, of that one only: the shell asks only for the server it shows); reached by their `~/.ssh/config` alias if there is one (same name or same address), otherwise by their MagicDNS name. The others (phone…): state, OS, address, last seen. `servers_power` (`anna servers on\|off\|reboot <name>`): shuts down or reboots over ssh (`sudo -n`, otherwise polkit), powers on with Wake-on-LAN using the MAC and broadcast recorded while online (`~/.local/state/anna/servers-wake.json`) — only on the same local network. CLI `anna servers`. |
| phone | `phone_watch` / `phone_action` | Phones paired with KDE Connect, through `kdeconnectd`'s D-Bus API (`busctl --json=short`, re-read every 2 s): battery, mobile network; actions: ring, ping, files (sftp), send the clipboard or a file, accept or decline a pairing. Its notifications do not go through anna: `kdeconnectd` sends them to the shell's notification server. `phone_screen` picks how to reach the screen (adb: a device already seen, USB first, otherwise `adb connect` on its Tailscale address, port 5555) and returns the `scrcpy` command, which the shell runs. `kdeconnectd`, `adb` and `scrcpy` come from the NixOS configuration. CLI `anna phone`. |
| tuner | `tuner_watch` | Pitch detection — `{"pitch":<hz>}` per frame. |
| chroma | `chroma_watch` | 12-class chromagram — `{"chroma":[…],"top":[…]}`. |
| metronome | `metronome` | Sample-accurate click session, `{"beat":<n>}`. BPM bounded to 20–300, beats per bar to 1–16. |
| gestures | `gesture_get` / `gesture_set` / `gesture_toggle` / `gesture_watch` / `gesture_cameras` / `gesture_set_camera` | Webcam control (pointer, window grabbing, workspace switching). **Off by default**. |

## Languages

anna follows the two languages picked in the settings
(`~/.config/karenine/locale.json`): the messages it shows on screen (errors,
notices) are in the **interface language**, whisper transcribes and the pilot
answers in the **voice language**. Its messages are the `anna.*` keys of the
shell's dictionaries, read at run time: a language added to `i18n/` also
translates anna, without rebuilding it. See [Languages](#languages).

## Native audio

The audio services use [`cpal`](https://crates.io/crates/cpal) (microphone
capture for the tuner/chromagram, click playback for the metronome) and
[`rustfft`](https://crates.io/crates/rustfft) for the DSP. All frequency math
is derived from the **device's real sample rate** (often 48 kHz), so no
resampling is needed. Each audio service opens its own capture — the audio
server (PipeWire) multiplexes clients, as the old concurrent `parec` did.

## Conventions

- A “watch” service keeps the connection open and **pushes** JSON lines;
  the matching microphone capture only runs in `anna` while the socket is
  open (the widget connects/disconnects with its visibility).
- On the QML side, we use the `Socket` type of `Quickshell.Io` (see
  `widgets/HardwareStats.qml`, `widgets/Tuner.qml`, `widgets/ChromaGraph.qml`,
  `widgets/Metronome.qml`).
- The audio tools are detailed in [Music tools](#audio-tools).
