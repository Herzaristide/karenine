---
title: Music tools
group: Features
summary: Tuner, metronome, chromagram and recording — QML widgets + native audio services of the anna daemon.
links: [widgets, backend, shell]
---

# Music tools

karenine ships a small suite for music practice, each tool being a
[widget](#widgets) backed by a native audio service of the
[`anna`](#backend) daemon. The metronome and the tuner share the “Music”
tab:

![The Music tab: metronome above, tuner below](screenshots/music.webp)

## Tuner

- Widget: `widgets/Tuner.qml` (the “Music” tab, `widget:musique` or
  `widget:accordeur` through the [IPC](#shell)).
- Backend: `anna`'s `tuner` service (`tuner_watch`) — pitch detection by FFT
  autocorrelation, one `{"pitch":<hz>}` line per frame.

## Chromagram (ChromaGraph)

- Widget: `widgets/ChromaGraph.qml`.
- Backend: `anna`'s `chroma` service (`chroma_watch`) — 12-class chromagram,
  `{"chroma":[…],"top":[…]}` per frame.

## Metronome

- Widget: `widgets/Metronome.qml`, the face of `services/Tempo.qml`, which
  holds the tempo, the measure and the session: it keeps beating with the
  tab closed.
- Control without the widget: the pilot's `metronome` tool (« lance le
  métronome à 90 », « arrête le métronome »), or the [IPC](#shell):
  `echo "metronome:lancer:120:4" > /tmp/qs-panel.fifo`, `metronome:arreter`,
  `metronome:basculer` (tempo and beats per bar optional).
- Backend: `anna`'s `metronome` service — sample-accurate `cpal` output
  stream, driven by `{"action":…}` lines, `{"beat":<n>}` events.

## Recording

- Sound: `widgets/AudioRecorder.qml`, under the tuner — the microphone alone
  (« Mic ») or with what the computer plays (« Mic + computer », to play
  over a track). FLAC in the Music folder.
- Screen: the button next to the screenshot in the top bar
  (`panels/HubTopBar.qml`) — click, a region; right click, the focused
  monitor; with the computer's sound. MP4 in the Videos folder. The bar
  hides first so it is not filmed.
- Backend: `anna`'s `record` service (`anna/src/recorder.rs`), followed by
  `services/Recorder.qml`. anna owns the recording, so it goes on when the
  tab or the bar closes; while it runs, the button turns red and shows the
  time elapsed, and a click stops it. The shortcuts (NixOS configuration)
  run `anna record audio mic|mix`, `anna record screen area|screen` — the
  same key starts and stops — and `anna record stop`.

## Common principle

The widgets connect to `anna`'s **socket** (`Quickshell.Io.Socket`) and
receive JSON lines. Microphone capture (tuner, chromagram) only runs while
the widget is visible. Details in [Backend](#backend).
