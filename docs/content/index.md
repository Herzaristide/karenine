---
title: Home
group: General
summary: karenine — a Quickshell interface (bar, panels, AI, music tools, lock screen) in QML, backed by one Rust daemon.
links: [architecture, shell, installation, widgets, search, lock-greeter]
---

# karenine

**karenine** is a [Quickshell](https://quickshell.org/) interface: a bar,
side panels, an AI chat, notes, hardware statistics, a suite of music
tools (tuner, metronome, chromagram, music player), and its own lock screen
and login screen.

![The widgets, opened above the conversation bar on the “System” tab](screenshots/stats.webp)

The project is made of **QML** for the interface and a single **Rust
daemon**, `anna`, for everything behind it (theme, stats, audio, AI,
notes…), plus a few assets. The upstream `quickshell` package lives in the
NixOS configuration that consumes this repository as a *flake input*.

## Where to start

- 🧭 [Architecture & conventions](#architecture) — layout and import rules.
- 🪟 [The shell & IPC](#shell) — `shell.qml` and FIFO control.
- 🧱 [The panels](#panels) and [the widgets](#widgets).
- 🔎 [Search](#search) — what the bar finds as you type.
- 🔒 [Lock & login screens](#lock-greeter) — `lock.qml` and `greeter.qml`.
- 📦 [Installation](#installation) — through the flake or by hand.
- 🌐 [Languages](#languages) — interface and voice languages, adding one.

## Main features

- **Bar + panels** on Wayland (see [Panels](#panels)).
- **Search** from the bar: applications, files, settings, wallpapers,
  notes, web (see [Search](#search)).
- **Lock screen and greeter** sharing one card (see [Lock & login
  screens](#lock-greeter)).
- **AI**: the desktop pilot and its voice (see [AI cluster](#ai)).
- **Music tools**: tuner, metronome, chromagram (see [Music
  tools](#audio-tools)).
- **Dynamic theme** driven by the `anna` daemon (see [Theme](#theme)).
- **Several languages**: English by default, French, and one JSON file per
  extra language (see [Languages](#languages)).
- **Relocatable**: no hard-coded path, backends are resolved relatively (see
  [Architecture](#architecture)).
