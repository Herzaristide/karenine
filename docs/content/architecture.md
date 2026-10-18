---
title: Architecture & conventions
group: General
summary: Repository layout and QML import rules (qmldir, relative paths, Qt.resolvedUrl).
links: [shell, panels, widgets, ai, backend, theme, languages]
---

# Architecture & conventions

## Repository layout

```
shell.qml            Quickshell entry point (bar + panels, IPC through a FIFO)
services/            Cross-cutting singletons (see Theme) and search sources
  Theme.qml, I18n.qml, ClaudeSessions.qml, Notifications.qml (notification server)
  claude-index.sh   (see “Scripts” below)
panels/              Top-level chrome (Wayland windows)
  ConversationBar, WidgetHub, HubTopBar, FloatingWidgets, WidgetCard,
  AiDock, PolkitPrompt
widgets/             Panel contents
  FileExplorer, HardwareStats, PhoneWidget, NotificationCenter, NotificationCard,
  MusicPlayerWidget, Metronome,
  Tuner, ChromaGraph, MiniGraph, GestureControls, Settings, DeviceSettings
i18n/                One dictionary per language (en.json, fr.json…)
anna/                Single Rust daemon (see Backend)
assets/              nixos.svg
```

Per layer: [the shell](#shell), [the panels](#panels),
[the widgets](#widgets), [the AI cluster](#ai), [the backend](#backend),
[the languages](#languages).

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
the bar's search and the [AI dock](#ai)'s history:

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
