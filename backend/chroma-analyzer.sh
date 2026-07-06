#!/usr/bin/env bash
# chroma-analyzer.sh — parec → chroma-analyzer.py wrapper.
#
# Streams raw mono microphone PCM (s16le @ 22050 Hz) into the Python chromagram
# analyzer, which prints STATUS:READY / CHROMA:… / TOP:… lines on stdout.
# Referenced by widgets/ChromaGraph.qml (resolved relatively via Qt.resolvedUrl).
set -u

# Directory of this script, so chroma-analyzer.py is found wherever installed.
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

PAREC_BIN="${PAREC_BIN:-parec}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PAREC_BIN" \
        --rate=22050 --channels=1 --format=s16le --raw \
        --latency-msec=20 \
        2>/dev/null \
  | "$PYTHON_BIN" -u "$DIR/chroma-analyzer.py"
