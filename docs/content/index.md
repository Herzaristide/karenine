---
title: Home
group: General
summary: karenine — a Quickshell interface (bar, panels, AI, music tools) in QML and scripts.
links: [architecture, shell, installation, widgets]
---

# karenine

**karenine** is a [Quickshell](https://quickshell.org/) interface: a bar,
side panels, an AI chat, notes, hardware statistics and a suite of music
tools (tuner, metronome, chromagram, music player).

The project is made of **QML** + **scripts** (bash/python) + assets. The
upstream `quickshell` package lives in the NixOS configuration that consumes
this repository as a *flake input*.

## Where to start

- 🧭 [Architecture & conventions](#architecture) — layout and import rules.
- 🪟 [The shell & IPC](#shell) — `shell.qml` and FIFO control.
- 🧱 [The panels](#panels) and [the widgets](#widgets).
- 📦 [Installation](#installation) — through the flake or by hand.
- 🌐 [Languages](#languages) — interface and voice languages, adding one.

## Main features

- **Bar + panels** on Wayland (see [Panels](#panels)).
- **AI**: Claude Code sessions and the desktop pilot (see [AI cluster](#ai)).
- **Music tools**: tuner, metronome, chromagram (see [Music
  tools](#audio-tools)).
- **Dynamic theme** driven by the `anna` daemon (see [Theme](#theme)).
- **Several languages**: English by default, French, and one JSON file per
  extra language (see [Languages](#languages)).
- **Relocatable**: no hard-coded path, backends are resolved relatively (see
  [Architecture](#architecture)).
