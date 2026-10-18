---
title: AI cluster
group: Features
summary: The AI dock (Claude Code sessions started, followed and reviewed from the interface), live sessions in the bar, the pilot's confirmations.
links: [panels, backend, widgets, languages]
---

# AI cluster

## The AI dock

`panels/AiDock.qml` is the interface's gateway to Claude. It sits against
the left edge of the screen and opens with Super+P; the pilot's
confirmations are answered there. It is the “sessions” widget, which the pilot (`widget` tool) or the FIFO
(`widget:sessions`, `savoir`) also open. Everyday use goes through the
conversation bar (`panels/ConversationBar.qml`, see [Panels](#panels)), whose
glass, tint (`Theme.glow`), Inter font and input capsule the dock reuses.

The text is not fixed: laid on blurred glass (`blur` layer rule on
“quickshell-aidock” in the Hyprland config), it is **expanded** (the whole
conversation, its work, the other views) or **collapsed** (the header, the
bottom of the conversation, the pilot's request and the field, to answer
or approve and nothing more), and can **disappear** entirely (×). It only
takes the keyboard exclusively for the time of a request, gives it back as
soon as the mouse leaves or moves away, and folds by itself when it loses
focus. Esc folds it, then makes it disappear; ⌃/⌄ switches between the two
sizes.

```
╭──────────────────────────────────────────────────────────╮
│ ● karenine·fix-dock                            working    │  the session watched
│ + new  ⟲ history  ◈ knowledge                             │
├──────────────────────────────────────────────────────────┤
│  the chosen session's conversation                       │
│  worktree-… · 2 files +14 −3   Zed Terminal Commit …      │  its work
│ ( › write to Claude                                 (↑) ) │
╰──────────────────────────────────────────────────────────╯
```

- **+ new**: choose where Claude works — research (the Obsidian vault,
  “researcher” style) or a repository — then write the request. In a
  repository, the session runs by default in an **isolated copy**
  (`claude --worktree`: `<repo>/.claude/worktrees/<name>`, branch
  `worktree-<name>`): the working code does not move until you merge.
- **A session**: its conversation updates as it goes; you answer it in the
  bottom field. A session opened in a terminal is read here but continued
  there (Terminal button), so that two processes never write into the same
  conversation.
- **Its work** (isolated copy): changed files and lines, commits to merge,
  then **Commit**, **Merge** (into the repository's current branch, refused
  if there are uncommitted changes on either side, aborted on conflict),
  **Discard** (two clicks), **Zed**, **Terminal** (the session is resumed
  there with `claude --resume`), **Stop**.
- **⟲ history**: the old conversations (`ClaudeSessions` index); picking one
  re-reads it, writing to it resumes it.

Keyboard: ⏎ sends, ⇧⏎ goes to a new line, Alt+←/→ changes session, Alt+N
opens a new session, Esc folds then hides the text.

Sessions started from here run in anna (`anna/src/claude/runner.rs`), not in
the QML: closing the dock or reloading the shell does not interrupt them.
They do die with anna (restart, rebuild) — their transcript stays, and
writing to them resumes them. Without a terminal, they have no permission
dialog: for now they only do what the Claude Code rules already allow,
anything else is refused.

| File | Role |
| --- | --- |
| `panels/AiDock.qml` | The AI dock. |
| `services/ClaudeLive.qml` | Live sessions, followed conversation, commands to anna. |
| `anna/src/claude/runner.rs` | Starts, resumes, restarts and stops the dock's sessions; opens Zed or a terminal. |
| `anna/src/claude/transcript.rs` | Reads a session's JSONL and follows its growth. |
| `anna/src/claude/worktree.rs` | Review, commit, merge and removal of isolated copies. |

## Knowledge

“◈ knowledge”, in the dock (or `echo savoir > /tmp/qs-panel.fifo`), shows the
Obsidian vault `~/v4ult`: research notes, project notes, skills, lab, and the
session journal written by the `claude-journal` hook.

- **Filters**: all, to review, research, projects, skills, lab, journal, with
  their count. What you type in the bottom field narrows the list; Enter
  opens the first note.
- **Preview** on the right (Markdown, without the front matter), with
  **Reviewed** for a note Claude filed (`statut: relu`, `revu: <today's
  date>`, written in place), **Session** to reopen the conversation it comes
  from (`session` field), and **Obsidian** to open it there.
- **◈ Capitalize**, in the work bar of a session started from the dock, once
  its turn is over: sends it `/capitaliser`, which files away in the vault
  what it learned.

anna re-reads the vault every time the view opens
(`anna/src/claude/knowledge.rs`) and uses it to keep the skills active: each
`Skills/<name>/SKILL.md` is linked into `~/.claude/skills/`, and a link whose
note disappeared is removed. Nothing else in that folder is touched. The
pilot searches the same notes with `chercher_notes`.

The quick notes of the “Notes” tab (Keep-like, `notes.rs`) are a separate
store: the pilot writes one with `creer_note` (text, optionally pinned)
and reads them with `lire_notes` (optionally filtered by words).

## The pilot

The dock opens on the **pilot**: a Claude session (Haiku by default) that
anna keeps ready, to which you say what you want in a few words.

- **It acts on the desktop** with its tools (`anna/src/claude/desk.rs`):
  windows and workspaces, sound, brightness, media playback, applications,
  URLs, projects (Zed, terminal), screenshots, accent color, vault notes,
  desktop state, clipboard.
- **It hands deep work** — code, research — to a full session
  (`lancer_session`), in an isolated copy for a repository. It shows up at
  the top of the dock and in the bar.
- **It asks before the irreversible**: closing a window, running a shell
  command, rebuilding NixOS wait for an answer in the dock (Allow / Deny),
  which opens by itself, on behalf of a “pilot” session for the time of the
  question. Without an answer within 2 minutes, the action is not run.
- **It answers in the voice language** (see [Languages](#languages)): the
  language is part of the context of every request, so changing it applies
  from the next request on, without restarting the pilot. With “Automatic
  detection”, it answers in the language of the request.

An action confirmed in one sentence closes the dock; the confirmation stays
in the conversation bar. A longer answer, a question back or an error
stay displayed. “attach the clipboard” adds its text to the request;
“forget” starts again from a blank conversation.

Mechanics: `claude -p` in stream-json, with its own system prompt
(`--system-prompt`), without Claude Code's built-in tools (`--tools ""`),
with `anna mcp` as its only MCP server (`--strict-mcp-config`), without the
user's settings (`--setting-sources project`: no hooks, no journal) and
without a transcript on disk. Each request carries a context block: date,
language to answer in, active window, open windows, sound, sessions,
projects. The process is kept between two requests and restarted after
20 min of inactivity or 30 requests. Count about 2 s for a direct answer,
4 s on the first call with a tool.

Settings: `ANNA_PILOT_MODEL` (anna's environment variable) changes the
model; `~/.config/anna/pilote.md`, if it exists, is appended to the prompt
(preferred apps, habits, projects…).

| File | Role |
| --- | --- |
| `anna/src/claude/pilot.rs` | The pilot process, its prompt, the context, the thread of exchanges. |
| `anna/src/claude/desk.rs` | Its tools and their execution (Hyprland through Lua dispatchers). |
| `anna/src/claude/mcp.rs` | `anna mcp`: the MCP server (stdio) that presents them to it. |

## Voice

Two ways of speaking, and in both the text is written **while** you speak:

- **Super+V** (or `anna voice`, `echo voix > /tmp/qs-panel.fifo`): the
  sentence is written live in the conversation bar's field (the snowflake
  lights up), then goes to the pilot as if it had been typed. The answer
  shows above the bar, under the understood sentence to check it. The word
  “Karénine” and a click on the snowflake do the same.
- **Holding Space in the dock**: a dictation, as in Claude Code. Keep Space
  pressed and speak: the text is written live in the field (after what was
  already there). As long as the key is held, pauses do not cut. On release,
  the final transcript arrives (about 0.2 s) and **stays in the field**: you
  re-read, correct, then Enter sends. A normally typed space stays a space:
  dictation starts when Space is held 0.35 s without another key, and the
  space written on the press is then removed. The 🎙 starts the same
  dictation with the mouse; it stops at the end of the sentence.

With Super+V, the end of the sentence stops listening (a second press or a
click on the chip too). The chip shows “listening…” as long as nothing is
understood, then the text as it comes.

Everything is local: capture by anna (`cpal`), transcription by whisper.cpp
(“small” model, in the **voice language**, see below). Nothing leaves the
machine but the text, which goes where a typed request would.

### The voice language

The voice language is a setting of its own, separate from the interface's
(“Voice language”, under “Voice” in the settings): you can speak French to
an interface in English. It is whisper's language (`-l`) and the one the
pilot answers in. Three kinds of choice:

| Choice | Whisper | Pilot |
| --- | --- | --- |
| Same as interface (default) | the interface language | the interface language |
| Automatic detection | `-l auto`: whisper detects it | answers in the language of the request |
| A language (English, Français…) | that language | that language |

The warm whisper server keeps the language it was started with; if the
setting changes, it is restarted at the next word. Forcing the language
rather than detecting it is more reliable on short sentences.

### Live text

A whisper.cpp server stays loaded while you speak, and what has been said so
far is transcribed again every half second; the final transcript, over the
whole recording, replaces the provisional text.

- It runs on the dedicated graphics card (Vulkan), chosen from
  `vulkaninfo`: about 0.1 s per sentence on the RTX 3070, against nearly 2 s
  on the processor. Without a dedicated card, the processor takes over and
  the text follows the voice less closely.
- It starts with the first word and stops after 10 minutes without use, so
  that the dedicated card can go to sleep. The very first start of a
  whisper.cpp version compiles its shaders (a dozen seconds: no live text
  that time, the final transcript waits for the server); afterwards the
  graphics driver's cache brings the start under a second.
- If the server does not start, `whisper-cli` transcribes the recording at
  the end, without live text.

To try without speaking: `anna voice simulate file.wav [--send|--hold]`
runs a recording through exactly the same chain as the microphone, in real
time (without `--send`, nothing goes to the pilot; with `--hold`, like
holding Space: listening lasts until `anna voice release`).

### The wake word “Karénine”

Saying “Karénine” starts listening, like Super+V: “Karénine, turn the sound
down”. Turn it on or off with “○ Karénine” in the dock, or `anna voice wake
[on|off]`; the choice survives restarts. When on, the microphone stays
open: that is why the switch is in view.

- Every 80 ms, three small ONNX models (openWakeWord, on the processor,
  about 4 % of a core): a spectrogram, an “embedding” shared by all wake
  words, then the model specific to “Karénine” (200 KB), which scores the
  last second and a half between 0 and 1.
- Above the threshold (0.6; `ANNA_WAKE_THRESHOLD`), the last 2.5 seconds go
  before the request. **Whisper must hear “Karénine” at the start** of the
  first transcript; otherwise the turn stops silently (half a second of chip
  in the bar). Once confirmed, the word is removed from the request.
- `anna wake-score file.wav` gives the scores step by step, to tune the
  threshold.
- **The computer's sound is removed from the microphone.** The word and
  dictation listen to `echo-cancel-source` (`ANNA_VOICE_NODE`) through
  `pw-record`: PipeWire subtracts what the speakers play (WebRTC echo
  cancellation, `modules/audio.nix` in the NixOS config). “Karénine” is thus
  heard over music or a video, and a video that says it does not wake anna.
  Without that node, PipeWire gives the default microphone; without
  `pw-record`, anna opens the default microphone itself. The tuner and the
  metronome keep the raw microphone.

The model was trained in `~/ciph3r/lab/wakeword-karenine/`: openWakeWord's
official pipeline, but fed with **French** examples generated by Piper
(voices tom, siwis, upmc, gilles, plus libritts's 904 English voices reading
French phonemes), each checked by Whisper, and with neighboring words not to
confuse (Karine, Catherine, carabine…). On unseen synthetic French voices,
it recognizes about half of them, for one false trigger per hour of ordinary
sound: it mostly lacks real voices. Recordings of the user's voice are the
next improvement. The wake word does not depend on the voice language.

| File | Role |
| --- | --- |
| `anna/src/claude/wake.rs` | The detector and continuous listening. |
| `anna/models/wake/karenine.onnx` | The word's model (the other two come from openWakeWord). |

### End of sentence and cleanup

The sound level of the first moments gives the room's noise; speech is what
clearly exceeds it; 1.2 s of silence after speech ends the request. Without
speech within 6 s, listening stops on “nothing heard”. Stopped by hand
before any speech, it transcribes nothing.

Whisper “hears” things in silence and noise: subtitle credits (“Sous-titres
réalisés par…”, “Thanks for watching”), markers like `[BLANK_AUDIO]`,
`(musique)` or `*Bip*`. All of that is discarded.

Whisper's initial prompt lists the project names and a few terms (Zed,
dock, Obsidian…), in the voice language: without it, “karenine” becomes
“Carnine”.

The model: `ANNA_WHISPER_MODEL`, otherwise
`~/.local/share/anna/whisper/ggml-small.bin`, linked by the NixOS
configuration (a multilingual model: the `.en` models only know English).
The dictation built into Claude Code stays available in terminal sessions;
it is not used here: it only exists in its interface, and goes through a
private Anthropic service.

| File | Role |
| --- | --- |
| `anna/src/claude/voice.rs` | Listening, end of sentence, live text, sending to the pilot. |
| `anna/src/claude/whisper.rs` | The whisper.cpp server: card choice, language, start, stop. |

## Live sessions

All the machine's Claude Code sessions — started in a terminal or headless
— report to anna through their hooks (`anna hook`, declared in Claude Code's
configuration for SessionStart, UserPromptSubmit, PostToolUse, Notification,
Stop and SessionEnd). The `anna/src/claude/` module keeps their state;
`services/ClaudeLive.qml` follows it through `claude_watch`. Nothing pops up:
a waiting session shows in the dock and the bar, nowhere else.

Permission requests stay with Claude Code: its own dialog asks, in the
terminal. `anna hook` ignores a PermissionRequest that would still be
declared, so an old configuration does not hold Claude back.

| File | Role |
| --- | --- |
| `anna/src/claude/mod.rs` | The sessions' state: working / waiting / idle. |
| `anna/src/claude/hook.rs` | `anna hook`: forwards an event reduced to the bare minimum. |
| `anna/src/claude/permission.rs` | The pilot's confirmations, held until the dock answers. |
| `anna/src/claude/focus.rs` | Finds a session's window in the process tree. |

## Relations

- Hosted by the [panels](#panels).
- Its text follows the interface language, the pilot and whisper the voice
  language (see [Languages](#languages)).
