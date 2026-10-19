---
title: Widgets
group: Structure
summary: The panels' content — stats, notes, controls, graphs and music tools.
links: [panels, backend, audio-tools, theme, shell, languages]
---

# Widgets (`widgets/`)

The **content** shown in the [panels](#panels). Each widget is a standalone
QML component.

| Widget | Role |
| --- | --- |
| `FileExplorer.qml` | The “Explorer” tab: the computer's folders. Favorites on the left (the folders of the home directory, hidden ones excepted, then `/etc/nixos`), the path clickable segment by segment, the content as tiles (images as thumbnails). As in a file manager, a click selects and a double click enters a folder or opens a file (`xdg-open`, the bar fades out); a tile can be dragged to another application (Dolphin, browser, messaging…), which receives the file as from a file manager. Multiple selection: Ctrl+click adds or removes, Shift+click takes a range, a click in the void deselects; dragging a selected tile carries the whole selection; a chip says how many are selected, and clears them; the buttons show hidden files, open the folder in the file manager or a terminal. The folder is kept from one tab to another. Above the favorites, a picker switches from this machine to the tailnet's servers (the list from `anna servers list`, those reachable over ssh): the server is mounted with `sshfs` (`host:/`, under `$XDG_RUNTIME_DIR/karenine-sshfs/<name>`, `BatchMode`: an ssh key is required) and stays mounted until switching to another machine; its favorites are the folders of its home directory and its NixOS config (the root goes through the “/” disk, the path or ↑); the terminal opens an ssh session in the same folder there; no thumbnails remotely. At the bottom, full width, one chip per physical disk of the machine shown (`df -l` and `lsblk`, over ssh remotely), with how full it is; a click goes to its main mount point. A failed sample (ssh) keeps the disks shown and retries 5 s later. |
| `HardwareStats.qml` | The “System” tab: processor, memory and graphics card (the percentage large, the curve behind). At the top, a picker (`MachinePicker`) switches from this machine to a tailnet server: its sample comes from anna (`servers_watch`, over ssh, every 3 s, that server only), graphics card included (NVIDIA through `nvidia-smi`, else AMD through sysfs, the card with the most VRAM; asleep, a card is not read so as not to wake it and the tile says “Asleep”; awake, it is re-read at most every 15 s, to let it go back to sleep); on the right, its name, how long it has been up and its load, or the ssh error, then its actions: terminal (an ssh session in the system terminal), reboot and shut down (two presses; without password-less sudo, the terminal opens to type it); offline, power on with Wake-on-LAN, once its MAC has been recorded online. The machine choice is the same for the Explorer and the System tab (`Widgets.machine`). |
| `PhoneWidget.qml` | The phone linked through KDE Connect (anna, `phone.rs`), a wide, low card at the bottom of the “System” tab (`HardwareStats.qml`), whatever machine is picked there; `telephone` opens that tab. Its card: state, mobile network, battery; “Screen” shows it in a scrcpy window, ring, clipboard. Its notifications reach the “Notifications” tab, sent by `kdeconnectd` like any other. Accepts or declines a pairing request. |
| `NotificationCenter.qml` | The “Notifications” tab: the desktop notifications not closed yet, newest first (`services/Notifications.qml`, the shell being the `org.freedesktop.Notifications` server). Nothing pops up over the screen. Each one (`NotificationCard.qml`): icon or image, application, time, title, text, its actions, an inline reply field when the application offers one; a click runs its default action, ✕ or a right click closes it. “Clear all” closes them all. |
| `NotesWidget.qml` | The “Notes” tab: a Keep-like wall of cards, kept on this machine only (`anna notes …`, `notes.rs`: `~/.local/share/anna/notes/notes.json` and one file per image). A note is written in the bar: type it, then pick “Create a note” among the results (`services/NoteSource.qml`, which also lists the matching notes; picking one opens the tab). At the top of the tab, “Paste”; Ctrl+V on the wall turns the clipboard into a note: an image (a screenshot, an image copied from a browser), an image file copied from a file manager, or text. Every screenshot also lands there by itself: the daemon watches `/tmp/screenshot-*.png` (Print keys, search, pilot) and `<Pictures>/capture-*.png` (the top bar), and the tab reloads when `notes.json` changes. The cards, in columns that scroll, pinned ones first then the most recent: a click edits the text (an image's caption; Escape or a click elsewhere saves, emptying a text note deletes it), a double click opens an image; on hover, at the top right (icons `pin`, `copy`, `terminal`, `trash`), pin, copy back to the clipboard, open in Claude Code (`claude` in the system terminal, from the home directory, the note as its first message — an image by its path), delete. |
| `GlassButton.qml` | The widgets' button, in the bar's style (translucent pill, tinted if `accent`). |
| `MachinePicker.qml` | The machine choice, shared by the Explorer and the System tab: a chip named after the machine shown, which unrolls it and the tailnet servers reachable over ssh (`anna servers list`), online or not. The choice goes into `Widgets.machine`, the same for every tab; each one follows it (the Explorer mounts the server with sshfs when it comes back on screen, and goes back to the mounted machine if mounting fails). |
| `FocusRing.qml` | The outline of what has the keyboard, shared by all controls. |
| `MusicPlayerWidget.qml` | Music player. |
| `Tuner.qml` | Tuner — see [Music tools](#audio-tools). |
| `Metronome.qml` | Metronome — see [Music tools](#audio-tools). |
| `ChromaGraph.qml` | Chromagram — see [Music tools](#audio-tools). |
| `MiniGraph.qml` | Small reusable graph. |
| `Settings.qml` | Settings, in columns: devices; screen, tuner (the reference A, persisted by the `Tuning` singleton in `tuner.json`), voice (the wake word “Karénine”, through `Pilot.voiceWakeToggle()` — anna remembers it — and the **voice language**), **interface language**; appearance; palette (the Settings tab of `WidgetHub`). The two languages are separate settings: see [Languages](#languages). |
| `DeviceSettings.qml` | First column of the settings: sound output and input, webcam (PipeWire nodes, `wpctl set-default`); brightness and Bluetooth are in the top bar (`HubTopBar`). |
| `WifiSettings.qml` | Under the devices in the settings: the Wi-Fi radio on or off, the current network, and the visible networks (the eight strongest) to join, through NetworkManager (`nmcli`). A known network is joined in one click; an unknown protected one asks for its password in the row itself. Without a wireless interface, the section does not appear. |
| `BluetoothMenu.qml` | The Bluetooth menu, unfolded under its button in the top bar (`HubTopBar`). At the top, the adapter switch; then the devices: connected first, then paired, then the ones being discovered (the adapter scans while the menu is open, and stops when it closes). A click on a device: connected, it disconnects; paired, it connects; new, it pairs, becomes trusted (it will reconnect by itself) and connects. A connected headset with a microphone offers two modes: **Music** (A2DP, high-quality sound, no mic) and **Call** (HFP, the mic, phone-quality sound) — classic Bluetooth cannot do both at once. The modes are the PipeWire card profiles (`pactl list cards`). The headset only changes mode through this choice: WirePlumber's automatic switch is turned off in the NixOS configuration (`modules/audio.nix`), since anna's wake word listens all the time and the headset kept flipping. |
| `GestureControls.qml` | Webcam gesture control (anna): on/off, the engine's state and the camera to use. A floating card (`camera`), see [Panels](#panels). |
| `NotificationCard.qml` | One notification of the “Notifications” tab. |
| `NixIcon.qml` | A monochrome SVG icon tinted to the theme: the artwork ships white and is recolored, so one file serves light and dark. |

## In pictures

The “Explorer” tab — favorites on the left, the folder as tiles, the disk
chip at the bottom:

![The Explorer tab](screenshots/explorer.webp)

The “System” tab — processor, memory, graphics card, and the linked phone
below:

![The System tab](screenshots/stats.webp)

The “Player” tab, here with nothing playing:

![The Player tab](screenshots/player.webp)

The “Music” tab — the metronome above the tuner (see [Music
tools](#audio-tools)):

![The Music tab](screenshots/music.webp)

The “Settings” tab — sound, video and Wi-Fi; screen and tuner; appearance
and accent:

![The Settings tab](screenshots/settings.webp)

## Keyboard

Every widget action is reachable without the mouse. The outline in the bar's
tint (`FocusRing.qml`) shows what has the keyboard; a click does not make it
appear.

| Key | Effect |
| --- | --- |
| ↑ (empty field) | Opens the widgets; a second time, moves to the tabs. |
| ↑ ↓ (text typed) | Browse the suggestions, above the bar (↑ enters through the best one, against the bar; ↓ from it goes back to the field). Enter opens the chosen suggestion; ← → adjust the chosen volume or accent. |
| Arrows, Enter, Backspace (in the Explorer) | Move the cursor in the folder, open the file or enter the folder (Enter on several selected: opens them all), go up to the parent. Shift+arrows extend the selection, Space adds or removes, Ctrl+A takes everything, Esc clears the selection. Typing the first letters of a name jumps there; the mouse's “back” button goes up too. |
| ↓ (in the field) | Closes the widgets. |
| Tab / Shift+Tab | Move from one control to the next: top bar, widget, tabs, field. |
| Enter / Space | Press the button, the tile or the chip. |
| Shift+Enter | On the screenshot: the whole screen (like right click). |
| ← → / ↑ ↓ | Adjust sliders (volume, brightness), the track position (±5 s), the tempo, the A, the color pickers, the voice language (Shift: bigger step). |
| ← → | Change widget: from the empty field, the tabs, or any control that does nothing else with them. Ctrl+Tab too (Ctrl+Shift+Tab: backwards). |
| Esc | Gives the keyboard back to the field; in the field, drops the chosen suggestion, then closes the widgets, then the bar. |

The power buttons of the top bar act on the first press, without
confirmation. The floating card (gesture control) takes the keyboard once clicked; Esc closes
it.

## Relations

- Shown by the [panels](#panels), selected through the [shell's IPC](#shell).
- The music widgets (`Tuner`, `Metronome`, `ChromaGraph`) rely on
  [backend services](#backend) — grouped in [Music tools](#audio-tools).
- Their colors come from the [theme](#theme), their text from the
  [dictionaries](#languages).
