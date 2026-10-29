---
title: Panels
group: Structure
summary: The top-level chrome — conversation bar, widgets, floating widgets, polkit prompt.
links: [shell, widgets, ai, theme, search]
---

# Panels (`panels/`)

The **top-level chrome**: the Wayland windows that make up the interface.
They host the [widgets](#widgets) and are driven by [the shell](#shell).

| File | Role |
| --- | --- |
| `ConversationBar.qml` | The bottom bar, centered, hidden by default: it rises when you say “Karénine” or press Super, and leaves once the answer has been read. A flat, opaque card (Ajar's ink or paper, a hairline border) with the NixOS snowflake and the field that talks to the pilot. Listening and thinking turn its border to the accent color. The answer shows above it, on a card of the same surface: the request and a cross to close, the pilot's actions as chips, then its answer. What you type also [searches](#search) (applications, files, settings, wallpapers, notes, web): the suggestions stack just above, on a card of the same surface, the best one against the bar (↑ enters it); typing closes the hub, and so does sending a request to the pilot, to let its answer show. |
| `WidgetHub.qml` | The widgets, inside the conversation bar's capsule that the snowflake grows upwards: one widget at a time, full width (Explorer — the computer's folders —, System, Notifications, Notes, Player, Music — the metronome above the tuner —, Settings), a tab bar just above the field; above them all, the top bar (`HubTopBar.qml`, below). |
| `HubTopBar.qml` | The top bar of the widgets, the same whatever the tab: four flat groups. Power on the left (lock, suspend, log out, reboot, shut down — each acts on the first click); the levels in the middle (backlight brightness, volume; the sliders share the remaining width); Bluetooth (unfolds `BluetoothMenu.qml`, see [Widgets](#widgets)) and the screenshot (click: a region, right click or Shift+Enter: the whole screen, saved in the Pictures folder); the battery on the right. |
| `TabletBar.qml` | The touch bar: a band always there, stuck to the left edge, under the thumb of the hand holding the tablet; in portrait it moves to the bottom edge. Bare buttons, like the top bar's, without a background at rest. At the head, the battery, monochrome, the bolt inside it while charging, pulsing when it runs low — a tap unfolds its menu: the percentage, the state and the time left until empty or full; in the exact middle, the main workspaces (1–5, the others belonging each to its screen), the current one on an accent fill that slides from one to the next, the ones with windows in full text, the empty ones dimmed, and right below them the NixOS snowflake, which raises the conversation bar with its field ready, like Super (a second tap sends it back); at the foot, Wi-Fi, Bluetooth and power, each unfolding its menu next to the bar at its height (`WifiSettings`, `BluetoothMenu`, and the five power actions, which act on the first tap) — a tap beside it or on the same button folds it. It reserves its room (exclusive zone), stays under a fullscreen window and never takes the keyboard; its menu takes it on demand (a Wi-Fi password). |
| `FloatingWidgets.qml` | A full-screen surface, clickable only on its cards (`WidgetCard.qml`): only gesture control is left there, opened by anna. |
| `PolkitPrompt.qml` | The session's polkit agent: when an application asks for a system action (mounting a disk, managing a service, `pkexec`…), polkit sends the request here and this panel asks for the password (Cancel / Authorize). |

## In pictures

The bar alone, as it rises (Super or “Karénine”):

![The conversation bar](screenshots/bar.webp)

The widgets grown above it, here the “System” tab, with the top bar
(power, brightness, volume, Bluetooth, screenshot, battery) and the tabs
just above the field:

![The widget hub on the System tab](screenshots/stats.webp)

## Relations

- Opened/closed according to the state kept by [`shell.qml`](#shell) and the
  [IPC](#shell) messages.
- Their content comes from the [widgets](#widgets); the conversation bar talks
  to the pilot of the [AI cluster](#ai).
- Their look follows the [theme](#theme), their text the
  [interface language](#languages).
