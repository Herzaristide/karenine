---
title: The shell & IPC
group: Structure
summary: shell.qml, the Quickshell entry point, and external control through a FIFO.
links: [architecture, panels, widgets, configuration]
---

# The shell & IPC

`shell.qml` is the **Quickshell entry point**: it mounts the conversation
bar, the floating widgets and the polkit prompt. Which widgets
are open, and where, lives in the `services/Widgets.qml` singleton.

## External control (IPC through a FIFO)

The shell listens on a **FIFO**, `/tmp/qs-panel.fifo`, so it can be driven
from any script or shortcut — and that is how anna opens widgets when the
pilot calls its `widget` MCP tool:

```bash
echo "widget:stats"          > /tmp/qs-panel.fifo   # toggles a widget
echo "widget:lecteur:ouvrir" > /tmp/qs-panel.fifo   # ouvrir | fermer | basculer (open | close | toggle)
echo "widget:tout:fermer"    > /tmp/qs-panel.fifo   # closes everything
echo "dock"                  > /tmp/qs-panel.fifo   # raises / sends back the bar
echo "voix"                  > /tmp/qs-panel.fifo   # talks to the pilot
echo "close"                 > /tmp/qs-panel.fifo   # closes everything
```

These names are identifiers, shared with the pilot's tools: they do not
change with the interface language.

The widgets:

| Name | Widget |
| --- | --- |
| `explorer` | The computer's folders |
| `stats` | Hardware stats |
| `lecteur` | Player |
| `musique` | Metronome and tuner (`metronome` and `accordeur` lead there too) |
| `son` | Volume, audio outputs and inputs |
| `camera` | Gesture control |
| `reglages` | Settings window |

The old `widget:N` are still understood (0 = stats,
3 = musique, 4 = lecteur), as well as `controls` (son) and `camera`.

In practice, these messages are typically sent by Hyprland keybinds in the
NixOS configuration that consumes karenine.

## What the shell mounts

- The conversation bar and the floating widgets: see [Panels](#panels).
- The widgets' content: see [Widgets](#widgets).
- The bar's target screen is a [hard-coded setting](#configuration)
  (`primaryScreen`).
