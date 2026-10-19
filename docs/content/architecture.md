---
title: Architecture & conventions
group: General
summary: Repository layout and QML import rules (qmldir, relative paths, Qt.resolvedUrl).
links: [shell, panels, widgets, search, lock-greeter, ai, backend, theme, languages]
---

# Architecture & conventions

## Repository layout

```
shell.qml            Quickshell entry point (bar + panels, IPC through a FIFO)
lock.qml             Lock screen, a separate Quickshell instance
greeter.qml          Login screen, run by greetd
services/            Cross-cutting singletons and search sources
  Theme, I18n, Widgets, Display, Tuning, DragState
  Audio, Brightness, Battery, Notifications (notification server)
  Anna, ClaudeLive, ClaudeSessions, Gesture, CursorProbe, DefaultApps
  Search, Fuzzy, AppSource, FileSource, SettingSource, WallpaperSource,
  NoteSource, WebSource
  claude-index.sh   (see “Scripts” below)
panels/              Top-level chrome (Wayland windows)
  ConversationBar, WidgetHub, HubTopBar, FloatingWidgets, WidgetCard,
  AiDock, PolkitPrompt
widgets/             Panel contents
  FileExplorer, HardwareStats, MachinePicker, PhoneWidget, NotificationCenter,
  NotificationCard, NotesWidget, MusicPlayerWidget, Metronome, Tuner,
  ChromaGraph, MiniGraph, GestureControls, Settings, DeviceSettings,
  WifiSettings, BluetoothMenu, GlassButton, FocusRing, NixIcon
auth/                The card shared by the lock and login screens
lock/                Lock screen surfaces (music, stats)
greeter/             Login screen surface
i18n/                One dictionary per language (en.json, fr.json…)
anna/                Single Rust daemon (see Backend)
tests/               QML tests and contract checks (see Development)
assets/              Icons, nixos.svg
```

Per layer: [the shell](#shell), [the panels](#panels),
[the widgets](#widgets), [search](#search), [the lock & login
screens](#lock-greeter), [the AI cluster](#ai), [the backend](#backend),
[the languages](#languages).

## Services

The singletons of `services/` that are not a search source (those are on
the [Search](#search) page):

| Service | Role |
| --- | --- |
| `Theme.qml` | Colors and fonts, from anna (see [Theme](#theme)). |
| `I18n.qml` | `I18n.tr("key")`, the dictionaries of `i18n/` (see [Languages](#languages)). |
| `Widgets.qml` | Which widgets are open, and where; the machine picked for the Explorer and System tabs. |
| `Display.qml` | Which screen carries the interface. A screen is known by its **model**, not its connector (the same monitor is DP-4 on one machine and DP-3 on another). Fallbacks: the user's choice if plugged, else the default connector, else the first screen. The main workspaces (1–5) follow it, and are re-attached after every `hyprctl reload`. |
| `Audio.qml` | The default output's volume, live from PipeWire (capped at 100 %: above, PipeWire amplifies in software and saturates). |
| `Brightness.qml` | The laptop backlight (`brightnessctl`), re-read on every udev event — keys, anna or the shell — without polling. |
| `Battery.qml` | UPower over D-Bus, no polling. On battery, warns once at a low level and once at a critical one (desktop notification); plugging in re-arms them. Created at startup, so it watches even with nothing open. |
| `Notifications.qml` | The desktop notification server (notify-send, the browser, grimblast, the phone through kdeconnectd…). |
| `Anna.qml` | Where to reach the anna socket (`$XDG_RUNTIME_DIR`), in one place. |
| `ClaudeLive.qml` | The live Claude Code sessions as anna follows them (working / waiting / idle), and the AI dock's door to anna: start, write to, stop a session, review its work (see [AI cluster](#ai)). |
| `ClaudeSessions.qml` | The index of the Claude transcripts on disk (the dock's history). |
| `Gesture.qml` | The gesture control state, from anna. |
| `CursorProbe.qml` | The cursor position, asked on Hyprland's request socket (the answer of `hyprctl -j cursorpos`, without a process): a layer surface only sees the cursor when it hovers it. |
| `DefaultApps.qml` | The editor, file manager and terminal used to open a file, resolved from the system's settings (`xdg-mime`, `$TERMINAL`…), never hard-coded. |
| `Tuning.qml` | The tuner's reference A, persisted in `tuner.json`. |
| `DragState.qml` | A drag in progress: it necessarily takes the cursor out of the dock, which would close it and destroy the source card mid-gesture — this flag holds the closing back while dragging. |

## QML conventions

- **Every subfolder has a `qmldir`.** Components are imported by **relative
  path** (`import "../services"`, `import "../widgets"`, …).
- We **do not use** `import "root:/…"` — Quickshell advises against it: it
  breaks the LSP and singletons.
- **No user-facing text is written in the code**: it goes through
  `I18n.tr("key")` and lives in `i18n/` (see [Languages](#languages)).

## Embedded shell scripts

Work that is plainly shell work lives in `.sh` files next to the QML that
runs them, not in an escaped JavaScript string — an awk program in quotes
inside a QML string is neither readable nor testable. The current one feeds
the [AI dock](#ai)'s history:

| Script | Role |
| --- | --- |
| `services/claude-index.sh` | The index of the machine's Claude conversations, one TSV line per session. |

The indexer only reads both ends of each JSONL and runs in four processes
whatever the number of sessions — the naive version, a handful of
`grep`/`jq` per file, took 3 s where this one takes 50 ms. The cost is the
forks, not the disk.

The QML finds it through `Qt.resolvedUrl`, so it follows the installation
like the rest of the layout.

## Relocatable by design

- QML components are imported by **relative path**: no absolute path, the
  layout works whatever the installation prefix.
- The backend is reached through the **socket** `$XDG_RUNTIME_DIR/anna.sock`
  (no hard-coded path), which allows both [installation](#installation) modes.

## Audio flow (anna daemon)

The audio backend is native: `anna` captures the microphone and plays the
click through [`cpal`](https://crates.io/crates/cpal), and does the DSP with
[`rustfft`](https://crates.io/crates/rustfft). All the math is derived from
the **device's real sample rate** (no resampling). Details in
[Backend](#backend) and [Music tools](#audio-tools).
