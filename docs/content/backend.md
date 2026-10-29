---
title: Backend
group: Structure
summary: The anna Rust daemon — theme, hardware stats, servers, phone, notes, AI and audio (tuner, chromagram, metronome).
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
| record | `record_toggle` / `record_stop` / `record_get` / `record_watch` | Recordings, see [Music tools](#audio-tools). anna runs `ffmpeg` (the microphone, alone or mixed with the computer's sound, FLAC in `$XDG_MUSIC_DIR`) or `gpu-screen-recorder` (a `slurp` region or the focused monitor, with the computer's sound, MP4 in `$XDG_VIDEOS_DIR`), keeps them and stops them with SIGINT, so a recording outlives the bar and the shell's reloads. A notification gives the file. CLI `anna record audio [mic\|mix]`, `anna record screen [area\|screen]` (each starts, or stops the one running), `anna record stop`. `gpu-screen-recorder` comes from the NixOS configuration (`programs.gpu-screen-recorder`). |
| gestures | `gesture_get` / `gesture_set` / `gesture_toggle` / `gesture_watch` / `gesture_cameras` / `gesture_set_camera` | Webcam control (pointer, window grabbing, workspace switching). **Off by default**. |
| pilot | `pilot_ask` / `voice_toggle` / `speech_set` / … | The pilot, the voice that speaks to it (wake word, Parakeet) and its answers read aloud (Piper). Detailed in [AI cluster](#ai). |
| notes | CLI `anna notes list\|add\|paste\|edit\|pin\|copy\|delete\|sync` | The “Notes” tab. Works on the files directly, without the daemon: `$XDG_DATA_HOME/anna/notes/notes.json` (rewritten whole through a temporary file, so a crash never leaves half of it) and one file per pasted image. The clipboard is read with `wl-paste` (an image, then an image file copied from a file manager, then text). The daemon also turns every screenshot into an image note. |
| cloud | CLI `anna cloud status\|connect\|cancel\|disconnect`, `anna agenda <from> <to>` | The Nextcloud account (`~/.config/anna/cloud.json`; its app password in the Secret Service, through `secret-tool`). `connect` runs Nextcloud's Login Flow v2: the browser opens the server's login page, anna polls until the user grants access (20 min at most; `/anna-cloud-login.json` meanwhile). The daemon syncs the text notes with the Notes app (REST API) within seconds of a change here and every minute for the server's changes: `notes.json` stays the copy the shell reads, `sync.json` keeps the deletions still to send, `.lock` serializes the CLI and the daemon; a conflict goes to the newest side. `agenda` lists the event calendars over CalDAV and asks each for the range with `expand`, so the server unrolls recurring events and gives UTC times. The pilot reads it through its `agenda` tool. |

## Modules

| File | Role |
| --- | --- |
| `main.rs` | Entry point: the daemon, the socket server and the CLI subcommands. |
| `protocol.rs` | Every command, as a JSON object with a `"cmd"` field (e.g. `{"cmd":"set_accent","color":"#5277c3"}`). |
| `client.rs` | The CLI side: sends a command to the socket and prints the answer. |
| `paths.rs` | The filesystem locations shared by the daemon, the CLI and the helpers (socket, state, data), so they always agree. The QML side reads the socket path from `services/Anna.qml`. |
| `state.rs`, `color.rs` | The theme state: accent, light/dark mode, base16 palettes (embedded fallbacks), hex/HSL math and derived variants. |
| `templates.rs` | Renders the color templates: fragments under `~/.config/accent/fragments/`, imported by the declarative Nix configs; full files only where the app has no include (`kdeglobals`, Konsole's color scheme). |
| `appctl.rs` | Live reload after a color change: `hyprctl reload`, KDE D-Bus signals; Alacritty/WezTerm watch their file; the others pick it up on next launch. A failing step never blocks the others. |
| `msi.rs` | Mirrors the accent on the MSI keyboard (`$MSI_RGB_SET`), with a 200 ms debounce and a 2 s cooldown so bursts never wedge the controller; caches the last color for the boot and resume hooks. |
| `hwstats.rs`, `servers.rs`, `phone.rs` | Hardware stats, tailnet servers, KDE Connect phones (table above). |
| `audio.rs`, `tuner.rs`, `chroma.rs`, `metronome.rs` | Native audio (below). The voice reads the echo-cancelled mic through `pw-record` instead, which cpal cannot select. |
| `notes.rs` | The notes (table above). |
| `cloud/` | The Nextcloud account, the notes' sync and CalDAV (table above); a minimal XML reader for WebDAV's answers. |
| `recorder.rs` | The microphone and screen recordings (table above). |
| `i18n.rs` | anna's on-screen messages, read from the shell's dictionaries (below). |
| `claude/` | Pilot, voice, wake word, Parakeet, speech — see [AI cluster](#ai). |
| `gesture/` | Webcam capture, hand recognition and its output (pointer, windows, workspaces). |

## Languages

anna follows the two languages picked in the settings
(`~/.config/karenine/locale.json`): the messages it shows on screen (errors,
notices) are in the **interface language**, the pilot answers in the **voice
language** (Parakeet recognizes the spoken one by itself). Its messages are the `anna.*` keys of the
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
