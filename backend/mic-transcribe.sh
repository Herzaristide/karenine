#!/usr/bin/env bash
# Continuous microphone transcription.
# Streams what the mic hears to stdout (one line per detected utterance).
#
# Usage:   ./mic-transcribe.sh [language]
# Example: ./mic-transcribe.sh fr
#
# Requires: whisper-cpp (whisper-stream), pipewire/pulse, a working mic.

set -uo pipefail

WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.local/share/whisper/ggml-base.bin}"
LANG_CODE="${1:-${WHISPER_LANG:-fr}}"
THREADS="${THREADS:-4}"

# Download model if missing
if [ ! -f "$WHISPER_MODEL" ]; then
    echo "→ Téléchargement du modèle whisper..." >&2
    mkdir -p "$(dirname "$WHISPER_MODEL")"
    whisper-cpp-download-ggml-model base "$(dirname "$WHISPER_MODEL")" >&2
fi

# Make sure no other whisper-stream is hogging the CPU/mic
if pgrep -x whisper-stream >/dev/null; then
    echo "→ whisper-stream déjà lancé, on tue les anciennes instances" >&2
    pkill -x whisper-stream
    sleep 0.5
fi

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "🎤 Écoute en cours (langue=$LANG_CODE) — Ctrl+C pour arrêter" >&2

SDL_AUDIODRIVER=pulse whisper-stream \
    -m "$WHISPER_MODEL" \
    -l "$LANG_CODE" \
    --step 2000 \
    --length 5000 \
    --keep 200 \
    --vad-thold 0.4 \
    -t "$THREADS" \
    2>/dev/null \
    | stdbuf -oL tr '\r' '\n' \
    | while IFS= read -r line; do
        # Strip ANSI colors and trim whitespace
        line=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue
        case "$line" in
            '[BLANK_AUDIO]'|'[Musique]'|'(musique)'|'[silence]'|\
            '[Start speaking]'|'...'|'.'|\
            'main:'*|'whisper_'*|'load_backend:'*|'init:'*|'system_info:'*|\
            '['*'-->'*']'*) ;;
            *)
                printf '[%s] %s\n' "$(date +%H:%M:%S)" "$line"
                ;;
        esac
    done &
PID=$!
wait "$PID"
