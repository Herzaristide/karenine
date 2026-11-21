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
- Reference A4: under the meter (− +, the mouse wheel, ↑ ↓; a click goes
  back to 440 Hz), persisted by the `Tuning` singleton in `tuner.json`.

## Harmony

What the computer plays, as harmony — to improvise over a video or a song:
the chord to play over, the key it lives in, the 12 notes.

- Widget: `widgets/Harmony.qml`, at the heart of the player card
  (`MusicPlayerWidget`): the small spinning disc and the track on top, the
  harmony, then progress and controls; the lyrics (≡) take the whole top.
  On the left the chord to play over, large (held 120 ms before it shows,
  faded rather than blanked when the sound blurs), its notes, and the last
  four chords. On the right a circle of fifths that turns to the key: the
  scale is an arc of seven cells across the top, the chord's notes lit in
  accent, the tonic dotted, each note's energy as an inner ring; the key in
  the middle. An amber chip next to the track gives the recording's A when
  it is off by 6 cents or more (`A = 432 Hz`). Notes are spelled as the key writes them
  (B♭ in F major).
- Backend: `anna`'s `chroma` service (`chroma_watch`). It listens to **the
  output** — the monitor of the default sink, through `pw-record` with
  `stream.capture.sink` — not the mic, so the violin played over it does not
  count; the mic only as a fallback. One line per ~46 ms:
  `{"chroma":[12],"top":[3],"chord":{"name","root","tones"}|null,
  "key":{"tonic","minor","flats","scale","confidence"}|null,"tuning":<cents>}`.
- Analysis: interpolated spectral peaks on a 0.37 s window at 22.05 kHz,
  log-compressed; a harmonic gives most of its weight to its fundamental (a
  lone C no longer reads as C-E-G); the pitch grid follows the recording's
  measured tuning. Chord: templates (major, minor, 7, maj7, m7, dim, sus4)
  plus the bass on the root, through an HMM forward filter — a change shows
  in ~0.4 s. Key: Krumhansl–Kessler profiles on a 20 s chroma, after 4 s of
  sound, kept until another key is clearly better. Noise (spectral flatness
  over 0.35) gives no chord; 3 s of silence starts over.

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
  (`panels/TopIsland.qml`) — click, a region; right click, the focused
  monitor; with the computer's sound. MP4 in the Videos folder. The bar
  hides first so it is not filmed; the top bar stays, shrunk, to stop it.
- Backend: `anna`'s `record` service (`anna/src/recorder.rs`), followed by
  `services/Recorder.qml`. anna owns the recording, so it goes on when the
  tab or the bar closes; while it runs, the button turns red and shows the
  time elapsed, and a click stops it. The shortcuts (NixOS configuration)
  run `anna record audio mic|mix`, `anna record screen area|screen` — the
  same key starts and stops — and `anna record stop`.

## Common principle

The widgets connect to `anna`'s **socket** (`Quickshell.Io.Socket`) and
receive JSON lines. Capture (the mic for the tuner, the output for the
chromagram) only runs while
the widget is visible. Details in [Backend](#backend).
