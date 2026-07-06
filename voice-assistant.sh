#!/usr/bin/env bash
# Voice assistant daemon for QuickShell OllamaChat (no wake word).
# Continuously listens via sox VAD: each utterance is transcribed with
# whisper-cli and sent to the LLM. Activation is controlled by toggling
# the QuickShell voice button (the daemon runs only while enabled).
#
# Protocol (stdout lines):
#   STATUS:READY         - daemon ready
#   STATUS:LISTENING     - waiting for speech
#   STATUS:RECORDING     - capturing user voice
#   STATUS:PROCESSING    - transcribing
#   TRANSCRIPT:<text>    - transcribed user command (sent to LLM)
#   STATUS:SPEAKING      - TTS playing response
#   ERROR:<message>      - something went wrong
#
# Stdin commands:
#   SPEAK:<text>         - speak text via piper TTS

set -uo pipefail

# Whisper model. `base` is fast but transcribes French poorly; `small` is the
# sweet spot (~470 MB, decent on CPU, very good FR). Use `medium` if you have
# a GPU and want near-flawless French.
# Override via WHISPER_MODEL_SIZE=tiny|base|small|medium|large-v3
WHISPER_MODEL_SIZE="${WHISPER_MODEL_SIZE:-small}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.local/share/whisper/ggml-${WHISPER_MODEL_SIZE}.bin}"
PIPER_MODEL="${PIPER_MODEL:-$HOME/.local/share/piper/fr_FR-siwis-medium.onnx}"
WORK_DIR="/tmp/voice-assistant-$$"
SAMPLE_RATE=16000
WHISPER_LANG="${WHISPER_LANG:-fr}"
WHISPER_THREADS="${WHISPER_THREADS:-$(nproc 2>/dev/null || echo 4)}"

# Bias whisper toward French desktop-assistant vocabulary. The --prompt flag
# seeds the decoder with context so it stops emitting English tokens or
# common hallucinations when the audio is short/noisy.
WHISPER_PROMPT="${WHISPER_PROMPT:-Bonjour, ouvre le terminal, change la couleur, mets le volume, prends une capture decran, lance Firefox, ferme la fenetre, workspace, luminosite, NixOS, Hyprland.}"

# VAD tuning (sox silence params)
VAD_START_DUR="${VAD_START_DUR:-0.15}"
VAD_START_THOLD="${VAD_START_THOLD:-1.5%}"
VAD_STOP_DUR="${VAD_STOP_DUR:-1.8}"
VAD_STOP_THOLD="${VAD_STOP_THOLD:-1.5%}"
MAX_UTTERANCE="${MAX_UTTERANCE:-20}"   # seconds
MIN_BYTES="${MIN_BYTES:-5000}"         # ignore captures smaller than this

# Anti-feedback: pause the mic while TTS is playing (+ tail for echo/reverb).
POST_SPEAK_GRACE="${POST_SPEAK_GRACE:-0.4}"  # seconds of silence after TTS

mkdir -p "$WORK_DIR"
SPEAK_LOCK="$WORK_DIR/speaking.lock"

STDIN_PID=""
SOX_PID=""

cleanup() {
    [ -n "$STDIN_PID" ] && kill "$STDIN_PID" 2>/dev/null
    [ -n "$SOX_PID" ]   && kill "$SOX_PID" 2>/dev/null
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ensure_whisper_model() {
    if [ ! -f "$WHISPER_MODEL" ]; then
        echo "STATUS:DOWNLOADING_MODEL"
        mkdir -p "$(dirname "$WHISPER_MODEL")"
        whisper-cpp-download-ggml-model "$WHISPER_MODEL_SIZE" "$(dirname "$WHISPER_MODEL")" 2>/dev/null
    fi
}

ensure_piper_model() {
    if [ ! -f "$PIPER_MODEL" ]; then
        echo "STATUS:DOWNLOADING_VOICE"
        mkdir -p "$(dirname "$PIPER_MODEL")"
        local base_url="https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/medium"
        curl -sL "$base_url/fr_FR-siwis-medium.onnx" -o "$PIPER_MODEL"
        curl -sL "$base_url/fr_FR-siwis-medium.onnx.json" -o "${PIPER_MODEL}.json"
    fi
}

speak() {
    local text="$1"
    if [ -f "$PIPER_MODEL" ] && command -v piper >/dev/null 2>&1; then
        # Block mic capture for the whole duration of TTS playback,
        # otherwise the speaker output is picked up by the microphone
        # and looped back through whisper -> LLM.
        : > "$SPEAK_LOCK"
        # Kill any in-flight capture so sox stops listening immediately.
        if [ -n "$SOX_PID" ] && kill -0 "$SOX_PID" 2>/dev/null; then
            kill "$SOX_PID" 2>/dev/null
        fi
        echo "STATUS:SPEAKING"
        echo "$text" | piper -m "$PIPER_MODEL" --output-raw 2>/dev/null | \
            aplay -r 22050 -f S16_LE -t raw -q 2>/dev/null || true
        # Small tail to swallow speaker echo / room reverb before re-arming.
        sleep "$POST_SPEAK_GRACE"
        rm -f "$SPEAK_LOCK"
    fi
}

handle_stdin() {
    while IFS= read -r line; do
        case "$line" in
            SPEAK:*) speak "${line#SPEAK:}" & ;;
        esac
    done
}

# Capture one utterance via sox VAD, transcribe, emit
capture_one() {
    local outfile="$WORK_DIR/utterance.wav"
    local sox_err="$WORK_DIR/sox.err"
    local whisper_err="$WORK_DIR/whisper-cli.err"
    rm -f "$outfile" "$sox_err" "$whisper_err"

    # Wait until TTS playback (and grace period) is finished before listening.
    while [ -f "$SPEAK_LOCK" ]; do
        sleep 0.1
    done

    echo "STATUS:LISTENING"

    # sox blocks until VAD triggers, records until silence, then exits.
    sox -q -d -r "$SAMPLE_RATE" -c 1 -b 16 "$outfile" \
        silence 1 "$VAD_START_DUR" "$VAD_START_THOLD" \
                1 "$VAD_STOP_DUR"  "$VAD_STOP_THOLD" \
        trim 0 "$MAX_UTTERANCE" 2>"$sox_err" &
    SOX_PID=$!
    wait "$SOX_PID" 2>/dev/null
    SOX_PID=""

    # If sox was killed because TTS started, drop this capture entirely
    # (it almost certainly contains the assistant's own voice).
    if [ -f "$SPEAK_LOCK" ]; then
        rm -f "$outfile"
        return 0
    fi

    local filesize
    filesize=$(stat -c%s "$outfile" 2>/dev/null || echo 0)

    if [ "$filesize" -lt "$MIN_BYTES" ]; then
        # "trim: Last N position(s) not reached" is a normal sox warning that
        # appears whenever the utterance is shorter than MAX_UTTERANCE seconds
        # (always). Filter it out so it doesn't surface as a UI error.
        local real_err
        real_err=$(grep -v 'WARN trim:' "$sox_err" 2>/dev/null \
                    | tail -n1 | tr -d '\n' | cut -c1-80)
        if [ -n "$real_err" ]; then
            echo "ERROR:Capture audio échouée ($real_err)"
            sleep 1
        fi
        return 0
    fi

    echo "STATUS:PROCESSING"

    local transcript
    # -np: no progress  -nt: no timestamps
    # -bs/-bo: beam search + best-of for accuracy (FR benefits a lot)
    # -tp 0: deterministic decoding (no temperature fallback)
    # -t: use all CPU cores
    # --prompt: bias decoder toward French desktop vocabulary
    # Greedy decoding (-bs 1 -bo 1) is ~3-5x faster than beam search 5 and
    # gives essentially the same quality on short utterances. -tp 0 keeps
    # decoding deterministic. -nf disables temperature fallback (one pass).
    transcript=$(whisper-cli -m "$WHISPER_MODEL" -f "$outfile" \
            -l "$WHISPER_LANG" \
            -t "$WHISPER_THREADS" \
            -bs 1 -bo 1 -tp 0 -nf \
            --prompt "$WHISPER_PROMPT" \
            -np -nt 2>"$whisper_err" | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -v '^\[' | grep -v '^$' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || echo "")

    # Drop bracketed/parenthesized stage directions ([Musique], (soupir), *rires*, etc.)
    local cleaned
    cleaned=$(printf '%s' "$transcript" \
        | sed -E 's/\[[^]]*\]//g; s/\([^)]*\)//g; s/\*[^*]*\*//g' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | tr -s ' ')

    # Normalize for hallucination matching: lowercase, strip punctuation/spaces/accents
    local norm
    norm=$(printf '%s' "$cleaned" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 'y/àâäéèêëîïôöùûüÿç/aaaeeeeiioouuuyc/' \
        | tr -d '[:punct:][:space:]')

    # Length guard: under ~3 chars after cleaning, almost always noise
    if [ "${#norm}" -lt 3 ]; then
        return 0
    fi

    # Common whisper hallucinations on silence/noise/music
    case "$norm" in
        merci|mercibeaucoup|mercidavoirregarde|mercidavoirregardecettevideo|\
        sousttitrage*|sousttitres*|stitragesm|stitres*|\
        thankyou|thanksforwatching|thankyouforwatching|\
        bye|goodbye|byebye|\
        musique|lamusique|musiqueclassique|musiquedouce|musiquerock|\
        applaudissements|applaudissement|rire|rires|soupir|soupirs|\
        toux|raclement|silence|bruit|bruitage|bruitages|\
        vouspouvezvousabonner*|abonneztoi*|abonnezvous*|\
        sousmarin|sousmarins)
            return 0
            ;;
    esac

    [ -n "$cleaned" ] && echo "TRANSCRIPT:$cleaned"
}

main() {
    ensure_whisper_model
    ensure_piper_model

    echo "STATUS:READY"

    while true; do
        capture_one || true
    done
}

handle_stdin &
STDIN_PID=$!

main

