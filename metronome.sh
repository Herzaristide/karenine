#!/usr/bin/env bash
# metronome.sh — Sample-accurate metronome backend for the Quickshell
# Metronome widget.
#
# Design
# ------
#   • One persistent audio player (pw-cat / aplay / paplay) reads raw PCM
#     from a pipe attached to FD 9. Started once, never restarted.
#   • A "writer" subshell, started on START, repeatedly emits one beat's
#     worth of PCM (click + silence padding sized to the current BPM) on
#     FD 9. The audio backpressure (small playback buffer) paces the loop
#     to the sample clock, so timing is rock-solid with zero drift.
#   • Tempo / beats changes are picked up by the writer on the next beat.
#
# Protocol on stdin  : START [bpm] | STOP | BPM <n> | BEATS <n> | QUIT
# Output on stdout   : READY | BEAT <n>
# Audio diagnostics  : stderr (typically redirected to a log)

set -u

RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/quickshell-metronome"
mkdir -p "$RUN_DIR"
ACCENT="$RUN_DIR/accent.raw"
BEAT="$RUN_DIR/beat.raw"
STATE_BPM="$RUN_DIR/bpm"
STATE_BEATS="$RUN_DIR/beats"

# ── Pre-render click samples as raw 48 kHz mono s16le ─────────────────────
gen_clicks() {
    sox -q -n -r 48000 -c 1 -b 16 -e signed -t raw "$ACCENT" \
        synth 0.045 sine 1760 fade t 0.001 0.045 0.030 gain -3 || return 1
    sox -q -n -r 48000 -c 1 -b 16 -e signed -t raw "$BEAT" \
        synth 0.035 sine 880  fade t 0.001 0.035 0.025 gain -6 || return 1
}
if ! [ -s "$ACCENT" ] || ! [ -s "$BEAT" ]; then
    if ! gen_clicks; then
        echo "READY"
        echo "ERROR: sox failed" >&2
        exec cat >/dev/null
    fi
fi
ACCENT_BYTES=$(stat -c%s "$ACCENT")
BEAT_BYTES=$(stat -c%s "$BEAT")
export ACCENT BEAT ACCENT_BYTES BEAT_BYTES STATE_BPM STATE_BEATS

# ── Pick a player that reads raw 48 kHz mono s16le from stdin ─────────────
# Note: pw-cat uses libsndfile and refuses headerless stdin, so it's last.
PLAYER_CMD=""
if command -v aplay >/dev/null 2>&1; then
    # --buffer-size in frames (mono s16 ⇒ 1 frame = 2 bytes).
    # 4096 frames @48 kHz ≈ 85 ms — small enough that the writer blocks
    # within one beat at typical tempos, providing tight backpressure pacing.
    PLAYER_CMD="aplay -q -t raw -f S16_LE -r 48000 -c 1 --buffer-size=4096 -"
elif command -v paplay >/dev/null 2>&1; then
    PLAYER_CMD="paplay --raw --rate=48000 --channels=1 --format=s16le --latency-msec=50"
fi

if [ -z "$PLAYER_CMD" ]; then
    echo "READY"
    echo "ERROR: no audio player (pw-cat / aplay / paplay) found" >&2
    exec cat >/dev/null
fi

# ── Start the long-lived player. FD 9 is its stdin. ───────────────────────
# Process substitution gives us a writeable FD that the player reads from.
# We shrink the OS pipe buffer (F_SETPIPE_SZ = 1031) so the writer stays close
# to real time: the beat stream is paced purely by audio backpressure, and a
# small pipe keeps latency low without ever underrunning at typical tempos.
# If python3 is unavailable the resize is skipped (default 64 KiB pipe → higher
# latency, still perfectly regular).
exec 9> >(
    command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import fcntl; fcntl.fcntl(0, 1031, 8192)' 2>/dev/null
    exec $PLAYER_CMD >/dev/null 2>&1
)

echo "READY"

# ── State ────────────────────────────────────────────────────────────────
running=0
bpm=120
beats=4
WRITER_PID=""

write_state() {
    echo "$bpm"   > "$STATE_BPM"
    echo "$beats" > "$STATE_BEATS"
}
write_state

# ── Writer subshell ───────────────────────────────────────────────────────
# Continuous, gapless PCM stream paced by audio backpressure. Each iteration
# emits exactly one beat's worth of samples (click + silence padding to fill
# the whole beat interval). Because the samples are played back-to-back at a
# fixed 48 kHz sample clock, beat spacing is sample-accurate — no wall-clock
# sleep, no scheduler jitter, no underrun-recovery glitches. The write() on
# FD 9 blocks when the (deliberately small) pipe fills, which is what paces
# the loop to real time. BPM / beats are re-read every beat, so changes
# take effect on the next beat.
start_writer() {
    (
        trap 'exit 0' HUP TERM INT
        beat_index=0
        while :; do
            local_bpm=120; local_beats=4
            [ -r "$STATE_BPM" ]   && read -r local_bpm   < "$STATE_BPM"   || true
            [ -r "$STATE_BEATS" ] && read -r local_beats < "$STATE_BEATS" || true
            case "$local_bpm"   in ''|*[!0-9]*) local_bpm=120;;  esac
            case "$local_beats" in ''|*[!0-9]*) local_beats=4;;  esac
            [ "$local_bpm" -lt 20 ] && local_bpm=20
            [ "$local_beats" -lt 1 ] && local_beats=4

            # One beat of mono s16le @48 kHz. Compute in *samples* then ×2 so
            # beat_bytes is always even — an odd byte count would shift the
            # whole s16le stream by one byte and swap sample halves (garbled,
            # tempo-dependent noise).
            beat_bytes=$(( (48000 * 60 / local_bpm) * 2 ))

            echo "BEAT $beat_index"

            if [ "$beat_index" -eq 0 ]; then
                click="$ACCENT"; click_bytes=$ACCENT_BYTES
            else
                click="$BEAT";   click_bytes=$BEAT_BYTES
            fi

            cat "$click" >&9 || exit 0

            # Pad the rest of the beat with silence — this is what paces us.
            silence=$(( beat_bytes - click_bytes ))
            [ "$silence" -gt 0 ] && { head -c "$silence" /dev/zero >&9 2>/dev/null || exit 0; }

            beat_index=$(( (beat_index + 1) % local_beats ))
        done
    ) &
    WRITER_PID=$!
}

stop_writer() {
    if [ -n "$WRITER_PID" ]; then
        kill "$WRITER_PID" 2>/dev/null || true
        wait "$WRITER_PID" 2>/dev/null || true
        WRITER_PID=""
    fi
}

cleanup() {
    stop_writer
    exec 9>&-
}
trap cleanup EXIT INT TERM

# ── Command loop ─────────────────────────────────────────────────────────
while IFS= read -r line; do
    # Word-split intentionally
    # shellcheck disable=SC2086
    set -- $line
    cmd="${1:-}"
    case "$cmd" in
        START)
            [ -n "${2:-}" ] && bpm=${2}
            write_state
            if [ "$running" -eq 0 ]; then
                running=1
                start_writer
            fi
            ;;
        STOP)
            running=0
            stop_writer
            ;;
        BPM)
            [ -n "${2:-}" ] && bpm=${2}
            write_state
            ;;
        BEATS)
            [ -n "${2:-}" ] && beats=${2}
            write_state
            ;;
        QUIT)
            exit 0
            ;;
        *) ;;
    esac
done
