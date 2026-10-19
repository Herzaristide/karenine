---
title: Lock & login screens
group: Structure
summary: lock.qml (replaces hyprlock) and greeter.qml (replaces regreet) — two separate Quickshell instances sharing one authentication card.
links: [shell, installation, theme, languages, backend]
---

# Lock & login screens

karenine ships its own **lock screen** (`lock.qml`, replaces hyprlock) and
**login screen** (`greeter.qml`, replaces regreet). Both draw the **same
card** — machine, clock, user, password field, PAM state — on the same
backdrop, and differ only in what sits below the field.

## Layout

```
lock.qml             Lock screen entry point (ext-session-lock, PAM)
greeter.qml          Login screen entry point (greetd)
auth/                Shared by both
  AuthBackdrop       Backdrop: wallpaper, dark veil, two accent halos
  AuthVideo          Looping, muted wallpaper video (lock only)
  AuthCard           The central card: machine, clock, user, input, PAM state
  AuthClock          Large clock + date, in the interface language
  PasswordField      Masked field, send arrow, dots while PAM thinks, shake on failure
  CardRule           Thin separator between two sections of the card
lock/
  LockSurface        One surface per monitor: backdrop + card
  LockMusic          Compact MPRIS player (cover, title, transport)
  LockStats          CPU / RAM / GPU with a sparkline each, from anna
greeter/
  GreeterSurface     Backdrop + card with user choice, session, power buttons
```

The surfaces are **presentation only**: they emit `submitted(…)` and show
the state the entry point hands back. Authentication lives in `lock.qml`
and `greeter.qml`.

## The lock screen (`lock.qml`)

A **separate Quickshell instance** from the bar, started by hypridle /
`loginctl lock-session` (the lock button of the [top bar](#panels) too):

```bash
quickshell -p ~/.config/quickshell/lock.qml
```

Keeping it apart is deliberate: the bar can crash or reload without the
session unlocking, and the other way round.

- **Protocol**: `WlSessionLock` (ext-session-lock-v1), one surface per
  monitor. If this client dies without unlocking, the compositor **stays
  locked** — the security property of the protocol, but a crash here leaves
  a screen recoverable only from a TTY (Ctrl+Alt+F2) or SSH. Test any
  change to `lock.qml` with a TTY open next to it.
- **Authentication**: `PamContext` with the `quickshell` PAM service
  (`security.pam.services.quickshell` on the NixOS side). A second factor
  replaces the “Password…” prompt; a prompt that asks for a visible answer
  (2FA code) shows it in clear.
- **Primary screen only**: music (`LockMusic`) and hardware stats
  (`LockStats`, same anna stream as the System tab, reduced to CPU/RAM/GPU)
  are mounted on the primary monitor — otherwise every surface would open
  its own anna subscription. The music controls work without
  authentication, as on most desktops; set `interactive` to false to hide
  them.
- **Wallpaper video**: the compositor draws nothing under a locked screen,
  mpvpaper included, so the lock plays the video itself
  (`KARENINE_WALLPAPER`, set by the `lock-session` launcher; absent, a
  plain background). It pauses after a moment without mouse or keyboard
  (hypridle turns the screen off soon after) and resumes on the slightest
  movement. Only the lock depends on QtMultimedia.

## The login screen (`greeter.qml`)

Started by **greetd** in a dedicated Hyprland:

```bash
quickshell -p <karenine>/greeter.qml
```

- Same card, but the user can be changed, and the footer shows the session
  that will start and the **reboot / power off** buttons (logind accepts
  them from the greeter's active session).
- Authentication goes through the greetd socket (`$GREETD_SOCK`), not PAM
  directly; success **launches the session** (`start-hyprland`) instead of
  unlocking.
- The backdrop is see-through: mpvpaper plays the wallpaper underneath.
- `primaryScreen`, `defaultUser`, `sessionCommand` and `sessionName` are
  defaults that the Nix configuration substitutes. The language comes from
  `KARENINE_LANG` (see [Languages](#languages)), English otherwise.

### Preview mode

Outside greetd (no `$GREETD_SOCK`), `greeter.qml` runs as a **preview**:
nothing is sent anywhere, and Esc quits. Handy to retouch the look from the
session without logging out:

```bash
quickshell -p greeter.qml
```

There is no such mode for `lock.qml`: launching it really locks the
session.

## Look

Both screens follow the [theme](#theme): the accent tints the halos behind
the card, and without a wallpaper the backdrop takes the palette's base
color. The clock only ticks per minute — no seconds, no need to wake the
CPU sixty times a minute.
