---
title: Configuration
group: Usage
summary: The hard-coded defaults — the bar's screen and the accent color — and the settings kept on disk.
links: [shell, theme, installation, languages]
---

# Configuration

karenine has **two hard-coded defaults**:

## The bar's screen

In `shell.qml`:

```qml
primaryScreen: "DP-1"
```

It is the output that gets the bar by default (see [The shell](#shell)); the
Nix configuration substitutes this line. The “Screen” setting of the settings
window takes precedence: it names the screen by its **model** (stable from
one machine to another, unlike the connector) and is **persisted** in
`~/.local/share/quickshell/by-shell/<id>/display.json`. If the chosen screen
is unplugged, the bar falls back to `primaryScreen`, then to the first screen.

## Default accent color

In `services/Theme.qml`:

```qml
// #5277c3
```

This color is **overridden live** by the `anna` daemon when it runs; without
it, the built-in defaults apply (see [Theme](#theme)).

## Languages

The interface language and the voice language are picked in the settings
(“Interface language”, and “Voice language” under “Voice”) and kept in
`~/.config/karenine/locale.json`:

```json
{ "lang": "en", "voice": "fr" }
```

The interface is in English until another language is chosen. See
[Languages](#languages).

---

To install and deploy the layout, see [Installation](#installation).
