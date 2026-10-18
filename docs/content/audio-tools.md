---
title: Music tools
group: Features
summary: Tuner, metronome and chromagram — QML widgets + native audio services of the anna daemon.
links: [widgets, backend, shell]
---

# Music tools

karenine ships a small suite for music practice, each tool being a
[widget](#widgets) backed by a native audio service of the
[`anna`](#backend) daemon.

## Tuner

- Widget: `widgets/Tuner.qml` (**Pitch** panel, widget no. 3 through the
  [IPC](#shell)).
- Backend: `anna`'s `tuner` service (`tuner_watch`) — pitch detection by FFT
  autocorrelation, one `{"pitch":<hz>}` line per frame.

## Chromagram (ChromaGraph)

- Widget: `widgets/ChromaGraph.qml`.
- Backend: `anna`'s `chroma` service (`chroma_watch`) — 12-class chromagram,
  `{"chroma":[…],"top":[…]}` per frame.

## Metronome

- Widget: `widgets/Metronome.qml`.
- Backend: `anna`'s `metronome` service — sample-accurate `cpal` output
  stream, driven by `{"action":…}` lines, `{"beat":<n>}` events.

## Common principle

The widgets connect to `anna`'s **socket** (`Quickshell.Io.Socket`) and
receive JSON lines. Microphone capture (tuner, chromagram) only runs while
the widget is visible. Details in [Backend](#backend).
