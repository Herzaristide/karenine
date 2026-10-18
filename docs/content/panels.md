---
title: Panels
group: Structure
summary: The top-level chrome — conversation bar, floating widgets, AI dock, settings.
links: [shell, widgets, ai, theme]
---

# Panels (`panels/`)

The **top-level chrome**: the Wayland windows that make up the interface.
They host the [widgets](#widgets) and are driven by [the shell](#shell).

| File | Role |
| --- | --- |
| `ConversationBar.qml` | The bottom bar, centered, hidden by default: it rises when you say “Karénine” or press Super, and leaves once the answer has been read. A glass capsule (blurred by Hyprland) that stretches on a spring, the NixOS snowflake (it jumps and lights up when karenine listens) and the field that talks to the pilot. Listening and thinking surround it with an iridescent halo (surface `quickshell-conversation-glow`, unblurred). The answer shows above it, on a card of the same glass as the capsule: the request and a cross to close, the pilot's actions as chips, then its answer. What you type also searches (applications, files, settings, web): the suggestions stack just above, on a card of the same glass, the best one against the bar (↑ enters it); typing closes the hub, and so does sending a request to the pilot, to let its answer show. |
| `WidgetHub.qml` | The widgets, inside the conversation bar's capsule that the snowflake grows upwards: one widget at a time, full width (Explorer — the computer's folders —, System, Phone, Notifications, Player, Music — the metronome above the tuner —, Settings), a tab bar just above the field; above them all, the top bar (`HubTopBar.qml`: power; screenshot — click: a region, right click: the whole screen, saved in the Pictures folder —, backlight brightness, volume). |
| `FloatingWidgets.qml` | A full-screen surface, clickable only on its cards (`WidgetCard.qml`): only gesture control is left there, opened by anna. |
| `AiDock.qml` | The AI dock (“sessions” widget): a session's text, against the left edge on blurred glass — expanded (conversation, review, knowledge), collapsed (the bottom and the field) or hidden. |

## Relations

- Opened/closed according to the state kept by [`shell.qml`](#shell) and the
  [IPC](#shell) messages.
- Their content comes from the [widgets](#widgets); the AI panel hosts the
  [AI cluster](#ai).
- Their look follows the [theme](#theme), their text the
  [interface language](#languages).
