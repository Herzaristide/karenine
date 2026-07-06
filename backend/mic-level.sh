#!/usr/bin/env bash
# Streams microphone RMS levels to stdout so the OllamaChat voice indicator
# can render a live audio meter while the voice assistant is enabled.
#
# Output protocol (one line per ~32 ms chunk):
#   LEVEL:<float between 0.0 and 1.0>
#
# This script intentionally stays running for as long as QuickShell wants it:
# the mic-level Process in OllamaChat.qml is gated on `voiceEnabled`. parec
# multiplexes well, so it can read the same source as the sox VAD capture
# in voice-assistant.sh without conflicting.
set -u

PAREC_BIN="${PAREC_BIN:-parec}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# --latency-msec=10 pins PulseAudio's capture buffer to ~10 ms instead of the
# default ~2 s, which is what makes the meter feel real-time. We also use
# tiny --process-time-msec frames so parec hands data over to python every
# few ms rather than batching.
exec "$PAREC_BIN" \
        --rate=16000 --channels=1 --format=s16le --raw \
        --latency-msec=10 --process-time-msec=5 \
        2>/dev/null \
  | "$PYTHON_BIN" -u -c '
import sys, os, struct, math

CHUNK   = 160          # samples per emission (~10 ms at 16 kHz)
BYTES   = CHUNK * 2
NORM    = 32768.0
DECAY   = 0.72         # peak-hold falloff (smoother, less twitchy)
NOISE   = 0.010        # gate out idle background noise

# Force unbuffered binary stdin so we never wait on a full pipe buffer.
stdin = sys.stdin.buffer
stdout = sys.stdout

peak = 0.0
while True:
    buf = stdin.read(BYTES)
    if not buf:
        break
    if len(buf) < BYTES:
        # PulseAudio short read — process what we got rather than waiting.
        n = len(buf) // 2
        if n == 0:
            continue
        samples = struct.unpack("<%dh" % n, buf[: n * 2])
    else:
        n = CHUNK
        samples = struct.unpack("<%dh" % CHUNK, buf)
    acc = 0
    for v in samples:
        acc += v * v
    rms = math.sqrt(acc / n) / NORM
    if rms < NOISE:
        rms = 0.0
    # Log mapping so quiet speech still moves the bars, then peak-hold
    # decay so the meter does not flicker to zero between syllables.
    level = 0.0 if rms == 0.0 else max(0.0, min(1.0, (math.log10(rms) + 3.0) / 3.0))
    peak = max(level, peak * DECAY)
    stdout.write("LEVEL:%.3f\n" % peak)
    stdout.flush()
'
