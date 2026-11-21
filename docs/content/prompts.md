---
title: Prompts
group: Shell
summary: Every request the system makes of the user (passwords, confirmations) answered in karenine, not in foreign dialogs.
links: [architecture, backend, shell]
---

# Prompts

Linux asks the user through agents that can be replaced: polkit, the
askpass of ssh, git and sudo, the portals, NetworkManager, BlueZ… karenine
takes them over, so every request looks the same, is drawn under Wayland
(isolated from other clients, unlike `x11-ssh-askpass`) and takes the
keyboard exclusively while open.

## How a prompt travels

```
requester ──prompt_open──▶ anna (prompts.rs) ──prompt_watch──▶ Prompts.qml
   ▲                                                              │
   └──────────── answer ◀── prompt_reply ◀── PromptHost.qml ◀─────┘
```

- A prompt carries a title, a text, a detail, fields (`password`, `text`,
  `check`, `choice`) and buttons; Escape or a click beside the card answers
  `cancel`.
- Its id is 128 random bits; the answer goes back to its requester only,
  never to the other watchers, and is neither logged nor written to disk.
- It ends at its deadline (120 s by default, 600 s at most), or when its
  requester closes the connection.
- Without a shell following `prompt_watch`, anna refuses at once
  (`no_shell`): the requester falls back to the standard dialog.

polkit stays on Quickshell's own agent (`PolkitPrompt.qml`), drawn with the
same card (`PromptCard.qml`).

## The askpass

`anna-askpass` (`anna askpass <question>`) is meant for `SSH_ASKPASS`,
`GIT_ASKPASS` and `SUDO_ASKPASS`. It tells apart a secret, a user name, a
host key (« yes/no/[fingerprint] »), a confirmation (`SSH_ASKPASS_PROMPT=
confirm`, by the exit status) and a notice (`none`: « touch your security
key », killed by ssh once done). Who asks is read from its parent processes.
When anna or the shell is not there, the question goes to
`ANNA_ASKPASS_FALLBACK` (ksshaskpass, say), else the askpass fails.

## Sharing the screen

`anna-share-picker` (`anna share-picker`) is meant for xdph's
`screencopy:custom_picker_binary`. It reads what can be shared from
`XDPH_OUTPUT_SHARING_LIST`, `XDPH_WINDOW_SHARING_LIST` and
`XDPH_WORKSPACE_SHARING_LIST_V2`, and shows it as a prompt whose choice has
previews: the card turns into a grid of live tiles (`ChoiceTiles.qml`,
`ScreencopyView` of the screen, or of the window found by its Hyprland
address). « An area… » runs slurp once the card is closed. The answer goes
back as `[SELECTION]<flags>/<what>`, the `r` flag when « remember » is
ticked; printing nothing cancels. Without anna or the shell, the request goes
to `ANNA_SHARE_PICKER_FALLBACK`, else `hyprland-share-picker`.

Electron applications (and Chromium) ask the portal two or three times for
one share — the preview of their own picker, then the capture. Every request
within 8 s of a choice gets the same answer without the card, as long as the
screen or window still exists; the delay runs from the choice, so it cannot
stretch. The choice is kept in `$XDG_RUNTIME_DIR/anna-share-last` (0600).
