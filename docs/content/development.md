---
title: Development
group: Usage
summary: Validate the layout, run the tests, format, and what the CI checks.
links: [installation, backend, architecture, languages]
---

# Development

## Validate the layout

```bash
nix build .#default     # assembles the package (~/.config/quickshell)
nix flake check         # layout + qmllint (zero warnings) + QML tests + dictionaries + contract
```

## Tests

```bash
nix flake check         # everything below except cargo, in the Nix sandbox
cd anna && cargo test   # daemon
tests/run.sh            # QML (qmltestrunner, offscreen) — inside `nix develop`
tests/i18n-check.sh     # dictionaries: every key used exists in English
tests/contract-check.sh # QML ↔ anna: socket commands, qmldir entries
```

The campaign, layer by layer:

| Layer | Where | What it pins down |
| --- | --- | --- |
| Daemon | `anna/src/**` (`cargo test`) | theme and palettes, socket protocol (commands parsed, response shapes), client, tuner/chroma DSP, metronome timing, gestures, notes, servers, phone, pilot and speech, i18n |
| QML logic | `tests/tst_*.qml` | `Fuzzy` score tiers; `Search` debounce, stale answers, type bonus, cutoff, web fallback, result cap; `WebSource` address detection and encoding; `DragState` |
| Contract | `tests/contract-check.sh` | every `{"cmd":…}` the QML sends is a variant of `Command` in `protocol.rs`; every `qmldir` entry exists |
| Dictionaries | `tests/i18n-check.sh` | every key called by the QML or anna exists in `en.json` |
| Static | qmllint (in `nix flake check`) | zero warnings on every QML file |

The QML tests only load files that import **QtQuick alone**: the Quickshell
plugin does not load outside the `quickshell` binary. `tests/run.sh` copies
them into a separate folder, next to the doubles of `tests/stubs/`, which
stand in for what touches the system (`I18n`, `Theme`, `DefaultApps`, the
search sources). A `StubSource` records the query it was given; the test
emits `produced` itself to simulate the answer.

`tests/i18n-check.sh` fails when a key called by the QML (`I18n.tr`) or by
anna (`i18n::tr`) is missing from `i18n/en.json`, and lists, without failing,
the keys each other language still has to translate.

### By hand

What needs a real session (Wayland, PipeWire, BlueZ, a webcam) is checked
by hand after a change in that area, in the running shell — never in a
second `quickshell -p` instance, which breaks the IPC FIFO:

- **Bar**: search (an app, a file, an address), Enter opens the first result.
- **Widgets**: every tab opens; hardware stats move; the music player follows
  the current player.
- **Bluetooth / Wi-Fi**: toggle, list, connect; a headset switches between
  Music and Call.
- **Audio tools**: the tuner reads a tone, the metronome stays in time when
  the tempo changes.
- **Notifications**: `notify-send test` lands in the Notifications tab.
- **Lock**: `loginctl lock-session`, unlock with the password.
- **Pilot**: a request typed in the bar (or said after “Karénine”) acts on
  the desktop, and its answer shows above the bar.

## Format

```bash
nix fmt                 # formats flake.nix (nixfmt-rfc-style)
cd anna && cargo fmt    # formats the daemon
```

## What the CI checks

- **`cargo fmt --check`**, **`cargo clippy -D warnings`** and **`cargo test`**
  on the `anna` daemon
- **`nix flake check`**: layout, qmllint, QML tests, dictionaries, QML ↔ anna contract

See the daemon in [Backend](#backend), and the QML conventions in
[Architecture](#architecture).
