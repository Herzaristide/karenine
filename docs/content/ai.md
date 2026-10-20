---
title: AI cluster
group: Features
summary: The pilot (desktop actions asked from the conversation bar), the voice that speaks to it, and its answers read aloud.
links: [panels, backend, widgets, languages]
---

# AI cluster

## The pilot

What you type in the conversation bar (`panels/ConversationBar.qml`, see
[Panels](#panels)) goes to the **pilot**: a Claude session (Haiku by
default) that anna keeps ready, to which you say what you want in a few
words.

- **It acts on the desktop** with its tools (`anna/src/claude/desk.rs`):
  windows and workspaces, sound, brightness, media playback, applications,
  URLs, projects (Zed, terminal), screenshots, sound and screen
  recordings, accent color, vault notes, quick notes, widgets, desktop
  state, clipboard, and as a last resort a shell command. It never rebuilds NixOS.
- **It only acts**: it never starts a Claude Code session. A code or
  research task, it suggests opening the project (Zed or a terminal) and
  leaves it to you.
- **Nothing waits for a confirmation**: closing a window or running a shell
  command runs as soon as the pilot calls it. Its prompt asks it to use them
  only when the request is clear.
- **It answers in the voice language** (see [Languages](#languages)): the
  language is part of the context of every request, so changing it applies
  from the next request on, without restarting the pilot. With “Automatic
  detection”, it answers in the language of the request.

The answer shows above the bar: a one-sentence confirmation fades away, a
longer answer, a question back or an error stay displayed.

Mechanics: `claude -p` in stream-json, with its own system prompt
(`--system-prompt`), without Claude Code's built-in tools (`--tools ""`),
with `anna mcp` as its only MCP server (`--strict-mcp-config`), without the
user's settings (`--setting-sources project`: no hooks, no journal) and
without a transcript on disk. Each request carries a context block: date,
language to answer in, active window, open windows, sound,
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

**Super+V** (or `anna voice`, `echo voix > /tmp/qs-panel.fifo`): the
sentence is written **while** you speak, live in the conversation bar's
field (the snowflake lights up), then goes to the pilot as if it had been
typed. The answer shows above the bar, under the understood sentence to
check it. The word “Karénine” and a click on the snowflake do the same;
`anna voice dictate` only shows the transcript, without sending it.

The end of the sentence stops listening (a second press or a click on the
chip too). The chip shows “listening…” as long as nothing is
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

To try without speaking: `anna voice simulate file.wav [--send]` runs a
recording through exactly the same chain as the microphone, in real time
(without `--send`, nothing goes to the pilot).

### The wake word “Karénine”

Saying “Karénine” starts listening, like Super+V: “Karénine, turn the sound
down”. Turn it on or off under “Voice” in the settings, or `anna voice wake
[on|off]`; the choice survives restarts. When on, the microphone stays
open.

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
Obsidian, NixOS…), in the voice language: without it, “karenine” becomes
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

### Answers read aloud

The pilot's answer is spoken as it is written: each finished sentence is
synthesised while the next one comes, so the first words are heard about a
tenth of a second after the pilot writes them. Code blocks, links and
markdown marks are not read, and the pilot is told when its answer will be
heard (short sentences, no list). Saying “Karénine”, Super+V, a new request
or `anna voice hush` cut it short. The echo cancellation keeps the voice out
of the microphone: it does not wake anna.

Under “Voice” in the settings:

- **Read answers aloud**: never, when asked by voice (the default), or
  always (`anna voice speech off|voice|always`).
- **Reading voice**: one choice per installed voice, and per speaker for a
  voice that has several (`anna voice speaker <id>`).

Both are remembered in `~/.local/state/anna/speech.json`.

The voices are [Piper](https://github.com/OHF-Voice/piper1-gpl)'s (VITS
models, ONNX), run by anna itself with ONNX Runtime, like the wake word:
espeak-ng turns the text into phonemes (libespeak-ng, loaded at run time,
called as Piper calls it), the voice's map turns them into ids, the model
into sound, played by `pw-play`. No Python: Piper's own package pulls in
3.6 GB of training tools. On the processor, a sentence takes about a
twentieth of its duration to synthesise.

A voice is a `<name>.onnx` file and its `<name>.onnx.json`, in
`ANNA_PIPER_VOICES`, otherwise `~/.local/share/anna/piper/`, linked by the
NixOS configuration (French: `fr_FR-siwis-medium`, `fr_FR-upmc-medium` with
jessica and pierre, `fr_FR-tom-medium`). Without a choice, the first voice
of the voice language reads. The loaded voice is released after 10 minutes
of silence. `anna say "text" [file.wav]` speaks a text without the daemon,
and gives the synthesis time per sentence.

| File | Role |
| --- | --- |
| `anna/src/claude/speech.rs` | Text cleanup, phonemes, synthesis, playback, settings. |

## Relations

- Hosted by the [panels](#panels).
- Its text follows the interface language, the pilot and whisper the voice
  language (see [Languages](#languages)).
