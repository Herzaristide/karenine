---
title: AI cluster
group: Features
summary: The pilot (desktop actions asked from the conversation bar), and the voice that speaks to it.
links: [panels, backend, widgets, languages]
---

# AI cluster

## The pilot

What you type in the conversation bar (`panels/ConversationBar.qml`, see
[Panels](#panels)) goes to the **pilot**: a conversation anna holds itself with a model —
a local one served by Ollama (by default), or a remote one through an API
with a key — to which you say what you want in a few words. No agent runs
beside it: anna calls the model, then the tools it asks for.

- **It acts on the desktop** with its tools (`anna/src/claude/desk.rs`):
  windows and workspaces, sound, brightness, media playback, applications,
  URLs, projects (Zed, terminal), screenshots, sound and screen
  recordings, accent color, vault notes, quick notes, the calendar (read
  only, `agenda`), the metronome (start, stop, tempo, without opening
  its widget), widgets, desktop
  state, clipboard, and as a last resort a shell command. It never rebuilds NixOS.
- **It answers questions** like a general assistant (knowledge,
  explanations, definitions, conversions, advice…), from what it knows.
  It has no search engine: it reads a page whose address it has
  (`lire_page`: the page's text, at most 12 000 characters), and for what
  is recent or changes — news, weather, prices — it says what it does not
  know and offers to open a search in the browser. A question about what
  you noted goes to your notes first.
- **It looks at your screen** when the question is about it (« c'est quoi
  cette erreur ? », « résume cette page », « décris ce qu'il y a à
  l'écran ») : `voir_ecran` grabs the focused monitor with `grim` (JPEG, at
  most 1568 px on its long side, never written to disk) and hands it back to
  the model as an image in the tool result. Given a window (`cible`: its
  class or a piece of its title — « regarde mon Firefox »), it grabs that
  window alone, if it is on a workspace shown on some monitor; one out of
  sight is not shown for it (that would change what you see) — it says so.
- **It does no code work**: a code task on a project, it suggests opening
  the project (Zed or a terminal) and leaves it to you.
- **Nothing waits for a confirmation**: closing a window or running a shell
  command runs as soon as the pilot calls it. Its prompt asks it to use them
  only when the request is clear.
- **It answers in the voice language** (see [Languages](#languages)): the
  language is part of the context of every request, so changing it applies
  from the next request on, without restarting the pilot. With “Automatic
  detection”, it answers in the language of the request.

The answer shows above the bar: a one-sentence confirmation fades away, a
longer answer, a question back or an error stay displayed.

Mechanics: anna speaks the Anthropic Messages API itself (`POST
<address>/v1/messages`, streamed), which Ollama serves as well as
Anthropic's API: its system prompt, the desk tools (`desk.rs`, in the API's
shape), and the conversation so far. The answer streams into the bar word
by word; when the model asks for tools, anna runs them one after the other
through the daemon (the `desk` command, as `anna mcp` has them run), hands
the results back (the screen as an image), and calls it again — at most 16
times for one request. Thinking is off unless asked for (`think`); a local
model's thinking is never sent back. Each request carries a context block:
date, language to answer in, active window, open windows, sound, projects.
The conversation is kept between requests (at most 40 messages, the oldest
requests dropped whole; a screenshot only for the request that took it, its
line of text after) and forgotten after 20 min of inactivity or 20
requests. With Ollama, the model is asked to load as soon as you start
speaking. The context block of a spoken request is built while its last
words are transcribed. Nothing is written to disk but the settings.

Settings (Settings › Assistant, `widgets/AssistantSettings.qml`): the
provider — **Ollama** (a local model, `http://localhost:11434` by default,
no key) or the **Anthropic API** (`https://api.anthropic.com`, with a key) —
its address, the model (the list the provider gives: Ollama's installed
models, or the API's), and whether it thinks before answering. They are
saved in `~/.config/anna/pilot.json`; the key apart, in
`~/.config/anna/pilot.key` (mode 600), or in `ANNA_PILOT_API_KEY`. Every
change starts the conversation over. Ollama's context window must hold the
prompt and the tools — about 5 300 tokens before the first word: with
Ollama's default of 4096, it silently drops half of it. Set
`OLLAMA_CONTEXT_LENGTH` to 16384 on the Ollama service (on an 8 GB GPU,
`qwen3.5:9b` then stays wholly in VRAM; at 32k it spills over). `~/.config/anna/pilote.md`, if it exists, is appended to the
prompt (preferred apps, habits, projects…).

| File | Role |
| --- | --- |
| `anna/src/claude/pilot.rs` | The pilot: its settings, its prompt, the context, the conversation with the model and its tool calls. |
| `anna/src/claude/desk.rs` | Its tools and their execution (Hyprland through Lua dispatchers). |
| `anna/src/claude/mcp.rs` | `anna mcp`: the desk tools as an MCP server (stdio), for any MCP client; and the call to the daemon the pilot uses too. |
| `widgets/AssistantSettings.qml` | Its settings: provider, address, key, model, thinking. |

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

Everything is local: capture by anna (`cpal`), transcription by Parakeet
(NVIDIA's Parakeet TDT 0.6B v3, see below). Nothing leaves the machine but
the text, which goes where a typed request would.

### The voice language

The voice language is a setting of its own, separate from the interface's
(“Voice language”, under “Voice” in the settings): you can speak French to
an interface in English. It is the one the pilot answers in; the
transcription does not need it, Parakeet recognizes by itself which of its
25 European languages is spoken. Three kinds of choice:

| Choice | Pilot |
| --- | --- |
| Same as interface (default) | the interface language |
| Automatic detection | answers in the language of the request |
| A language (English, Français…) | that language |

### Live transcript

Parakeet stays loaded while you speak, and what has been said so far is
transcribed again every half second, on a thread of its own so that the end
of speech is still watched meanwhile (it confirms the wake word, and the
last pass, made just after the end of speech, is the final transcript); the final transcript,
over the whole recording, replaces it. The bar does not show it: its
snowflake turns while anna listens and transcribes, and the request
appears once sent.

- It runs on the processor, in ONNX Runtime (the same as the wake word's): about 0.3 s for a sentence on bernanos's i7, six times
  faster than whisper “small” there, and no graphics card needed. Unlike
  Whisper, which always encodes 30 s of audio, it only encodes what was
  said, and its TDT decoder skips silence and long sounds.
- It is loaded with the first word (about 3 s) and dropped after 10 minutes
  without use, to give back its memory (about 1 GB) — not while the wake
  word is on: it is then loaded with it and kept, so that a turn it starts
  never waits for the loading. A request said while
  it loads waits for it at the end.

To try without speaking: `anna voice simulate file.wav [--send]` runs a
recording through exactly the same chain as the microphone, in real time
(without `--send`, nothing goes to the pilot).

### The wake word “Karénine”

Saying “Karénine” starts listening, like Super+V: “Karénine, turn the sound
down”. Turn it on or off under “Voice” in the settings, or `anna voice wake
[on|off]`; the choice survives restarts. When on, the microphone stays
open.

**Each machine answers to its own name.** The word is `ANNA_WAKE_WORD`: the
NixOS configuration (`modules/common.nix`) sets it to the host name when
karenine ships a model by that name (“Bernanos” on bernanos, “Exupéry” on
exupery), and to `karenine` otherwise; anna itself falls back on
“Karénine” without it. A word is two files in `anna/models/wake/`:

- `<word>.onnx`, its model, trained in `lab/wakeword-<word>/`;
- `<word>.json`, how it is written and heard: `display` (shown in the bar
  and the settings), `near` (how the transcript may write it, one to
  three words joined, folded: lowercase, no accents, “c” as “k”; within two
  letters counts),
  `neighbours` (folded words that don't count even when near), `initials`
  (the letters it may start with; those of `near` by default) and
  `threshold`.

The package lists the words that have a model (`anna.wakeWords`), which
the NixOS configuration reads to choose; adding a word is adding its two
files.

- Every 80 ms, three small ONNX models (openWakeWord, on the processor,
  about 4 % of a core): a spectrogram, an “embedding” shared by all wake
  words, then the model specific to the word (~400 KB), which scores the
  last second and a half between 0 and 1.
- Above the threshold (0.6; `ANNA_WAKE_THRESHOLD`), the last 2.5 seconds go
  before the request. **The transcript must hold “Karénine” among its
  first three words** (what came just before it is kept with it). Until
  it does, the bar rises without its accent border; confirmed, it turns
  to the accent. A short
  transcript without it is waited on — the word alone, Parakeet may not
  write it yet — and a longer one ends the turn silently. Once confirmed,
  the word is removed from the request.
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
clearly exceeds it; 1.2 s of silence after speech ends the request — 0.5 s
only if the transcript so far ends a sentence (`.`, `?`, `!`: Parakeet
punctuates). The microphone is brought down to 16 kHz through a windowed
sinc, which keeps what lies above 8 kHz from folding back over the voice. Without
speech within 6 s, listening stops on “nothing heard”. Stopped by hand
before any speech, it transcribes nothing.

Parakeet has no prompt, so no list of words to steer it: a name it does
not know comes out as it sounds. That matters for the wake word (above):
its `near` forms are how Parakeet writes it, and the journal shows what was
written either way (`anna: mot d'activation confirmé : « … »`, `… non
confirmé : « … »`), to add to them.

The model ships with the anna package (`anna/default.nix`, pinned to one
upstream revision), which points `ANNA_PARAKEET_MODEL` at it; without it,
anna looks in `~/.local/share/anna/parakeet/`. It is the int8 ONNX export of
[onnx-asr](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx),
four files — `nemo128.onnx` (16 kHz samples → NeMo's 128 log-mel bands),
`encoder-model.int8.onnx` (FastConformer, 650 MB),
`decoder_joint-model.int8.onnx` (the TDT decoder: the next token and how
many frames to skip) and `vocab.txt`. The dictation built into Claude Code
stays available in terminal sessions; it is not used here: it only exists
in its interface, and goes through a private Anthropic service.

| File | Role |
| --- | --- |
| `anna/src/claude/voice.rs` | Listening, end of sentence, live transcript, sending to the pilot. |
| `anna/src/claude/parakeet.rs` | Parakeet: loading, features, encoder, TDT decoding. |

## Relations

- Hosted by the [panels](#panels).
- Its text follows the interface language, the pilot the voice language
  (see [Languages](#languages)).
