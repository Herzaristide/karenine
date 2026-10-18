# karenine

A [Quickshell](https://quickshell.org/) interface: bar + side panels, AI,
notes, hardware stats, tuner / metronome / chromagram, music player. In
English by default, in French, and in any language added to `i18n/`.

QML + scripts (bash/python) + assets. The upstream `quickshell` package lives
in the NixOS configuration that consumes this repository as a *flake input*.

## Architecture

```
shell.qml            Quickshell entry point (conversation bar + widgets, IPC through a FIFO)
services/            Cross-cutting singletons
  Anna.qml             Path of the anna daemon's socket (shared by the widgets)
  Theme.qml            Theme state (reads state.json written by anna, built-in defaults)
  I18n.qml             Interface and voice languages, dictionaries of i18n/
  Display.qml          Choice of the interface's screen (persisted) + workspaces following it
  Gesture.qml          Webcam gesture control (driven by anna)
  Search.qml           Search aggregator + <Type>Source.qml (app, file,
                       web, setting, wallpaper, note), Fuzzy, DefaultApps, Audio
panels/              Top-level chrome (Wayland windows)
  ConversationBar      Bottom bar: snowflake (voice) + field that talks to the pilot, answer above
  WidgetHub            Tabbed widgets in the bar's capsule, which the snowflake grows
  FloatingWidgets      Floating gesture-control card (WidgetCard), opened by anna
  AiDock               AI dock (“sessions” widget): Claude sessions, conversation, review
widgets/             Content of the floating widgets
  FileExplorer, HardwareStats, PhoneWidget, NotificationCenter, NotificationCard,
  MusicPlayerWidget, Metronome,
  Tuner, GestureControls, ChromaGraph, MiniGraph, Settings, DeviceSettings
i18n/                One dictionary per language: en.json (reference), fr.json…
auth/                Central card shared by the lock and the greeter: background, clock, user, input
lock/                Lock screen (lock.qml): the card + music and stats
greeter/             greetd login screen (greeter.qml): the card + session and power
anna/                Single Rust daemon — theme, hwstats, network (Tailscale + ssh), tuner, chroma, metronome,
                     webcam gestures, Claude Code sessions (bar, AI dock),
                     pilot (desktop tools served over MCP), voice (whisper.cpp)
tests/               QML tests (qmltestrunner) — `tests/run.sh`; dictionaries — `tests/i18n-check.sh`
assets/              nixos.svg, icons/
```

Every subfolder has a `qmldir`. Components are imported by relative path
(`import "../services"`, `import "../widgets"`, …) — we do not use
`import "root:/…"` (advised against by Quickshell: it breaks the LSP and
singletons).

The whole backend is the Rust daemon `anna`: the widgets connect to it
through a **Unix socket** (`$XDG_RUNTIME_DIR/anna.sock`) and exchange JSON
line by line (`Quickshell.Io.Socket` type). No more bash/python backend nor
`parec`/`numpy` dependency (only one small script indexing Claude sessions
remains, `services/claude-index.sh`). Audio (tuner, chromagram, metronome) is
native through `cpal` + `rustfft`, at the device's real sample rate. (The
search and some widgets call system tools — see *External dependencies*
below.)

## Languages

Two separate settings, in the settings window: the **interface language**
(every text, dates, anna's messages) and the **voice language** (whisper and
the pilot's answers; “same as interface”, “automatic detection” or a given
language). Both are kept in `~/.config/karenine/locale.json`.

Every text lives in `i18n/<code>.json`, read by the QML (`I18n.tr("key")`)
and by anna (`anna.*` keys). **Adding a language means adding a file**: copy
`en.json`, set `_meta.name`, translate, run `tests/i18n-check.sh`. The
language then shows up in the settings by itself. Details in the
documentation, *Languages* page.

## External dependencies

The widgets' backend is entirely `anna` (see above), but the search and
some widgets drive system tools. They are called by their name in `$PATH`; none is required to start the shell, each one only disables its
own feature if missing.

| Tool | Used by | Without it |
| --- | --- | --- |
| `fd` | `services/FileSource.qml` | file search returns nothing |
| `jq` | `services/ClaudeSource.qml` | Claude conversations are not indexed |
| `wpctl` (wireplumber) | `widgets/DeviceSettings.qml` | the choice of output, input and webcam is empty |
| `brightnessctl` | `services/Brightness.qml` | the brightness setting does not appear |
| `udevadm` (systemd) | `services/Brightness.qml` | brightness no longer follows changes made elsewhere (keys, anna) |
| `grimblast` | `services/SettingSource.qml` | the screenshot card does nothing |
| `xdg-mime`, `xdg-open` (xdg-utils) | `services/DefaultApps.qml`, `FileSource` | roles fall back to the first known tool in `$PATH` |
| `claude-desktop` | `services/ClaudeSource.qml` | Claude Desktop sessions do not open (CLI ones do) |

The editor, file manager, terminal and browser are **never** hard-coded
names: `DefaultApps` resolves them from `xdg-mime` and `$TERMINAL`, falling
back to the first known candidate found in `$PATH`.

## Configuration

Two defaults are hard-coded:

- Default bar screen: `primaryScreen: "DP-1"` in `shell.qml` (substituted by
  the Nix config). The “Screen” setting (Settings tab of the widgets) takes
  precedence and is persisted in
  `~/.local/share/quickshell/by-shell/<id>/display.json`.
- Default accent color: `#5277c3` in `services/Theme.qml` (overridden live by
  the `anna` daemon when it runs; without it, the built-in defaults apply).

The greeter, which runs as another user, takes its language from
`KARENINE_LANG` (English otherwise).

## Installation

### Through the flake (recommended)

`packages.default` assembles the layout ready for `~/.config/quickshell`. In
the NixOS/Home-Manager configuration that consumes this flake:

```nix
home.file.".config/quickshell".source = karenine.packages.${system}.default;
```

### By hand (outside NixOS)

Copy/symlink the repository's content into `~/.config/quickshell/` (keeping
the subfolders), build `anna` (`cargo build --release` in `anna/`, needs
`alsa-lib` + `pkg-config`) and run it as a daemon, then run `quickshell`.
anna reads its messages from `~/.config/quickshell/i18n` (or
`KARENINE_I18N`).

## Development

- `nix flake check`: assembles the layout, runs all the QML through qmllint
  (zero warnings tolerated), runs the QML tests (`tests/run.sh`,
  qmltestrunner) and checks the dictionaries (`tests/i18n-check.sh`).
- `cd anna && cargo test`: daemon tests (theme, protocol, client, tuner and
  chromagram DSP, gesture recognition, translations…).
- `nix fmt`: formats `flake.nix`; `cargo fmt` in `anna/`.
- The CI checks `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`
  and `nix flake check`.
