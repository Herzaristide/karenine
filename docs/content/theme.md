---
title: Theme
group: Features
summary: services/Theme.qml — theme state, built-in defaults and integration with the anna daemon.
links: [configuration, widgets, panels, architecture]
---

# Theme (`services/Theme.qml`)

`Theme.qml` is a **singleton** (in `services/`) holding the theme state
shared by all [widgets](#widgets) and [panels](#panels).

## How it works

- Reads `~/.config/accent/state.json`, which the **`anna`** daemon rewrites on
  every change: the accent changes **live**.
- Sends changes (accent, mode, palette color, reset) through the `anna`
  client, one command at a time: a new value replaces the one still waiting,
  so the daemon only applies the latest.
- Without it, **built-in defaults** apply — including the accent color
  `#5277c3` (see [Configuration](#configuration)).

## Import

Like the other singletons, it is imported by relative path:

```qml
import "../services"
```

(see the conventions in [Architecture](#architecture)).

> The `anna` daemon is built by this repository (`anna/`, see
> [Backend](#backend)); karenine keeps working without it, with the default
> colors.
