#!/usr/bin/env bash
# tuner.sh — parec → tuner.py wrapper.
#
# Streams raw stereo microphone PCM (s16le @ 44100 Hz) into the Python pitch
# detector, which prints STATUS:READY / PITCH:<hz> lines on stdout. Referenced
# by widgets/Tuner.qml (resolved relatively via Qt.resolvedUrl).
set -u

# Directory of this script, so tuner.py is found wherever the repo is installed.
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

PAREC_BIN="${PAREC_BIN:-parec}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PAREC_BIN" \
        --rate=44100 --channels=2 --format=s16le --raw \
        --latency-msec=20 \
        2>/dev/null \
  | "$PYTHON_BIN" -u "$DIR/tuner.py"
