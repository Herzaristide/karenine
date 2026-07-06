#!/usr/bin/env python3
"""
chroma-analyzer.py — Real-time 12-bin chromagram for Quickshell.

Reads raw mono PCM (s16le @ 22050 Hz) from stdin, computes a chromagram
(energy per pitch class C..B) using a windowed FFT, and prints:

    STATUS:READY                                  — on startup
    CHROMA:v0,v1,...,v11                          — 12 normalized values [0..1]
    TOP:Note1,Note2,Note3                         — three loudest pitch classes

One CHROMA/TOP pair is emitted per analysis frame (~22 fps).
"""

import sys
import numpy as np

SR    = 22050
N     = 4096          # FFT window size  (~186 ms)
HOP   = 1024          # advance per frame (~46 ms → ~22 fps)
ALPHA = 0.55          # EMA smoothing factor for output
GATE  = 0.004         # RMS gate below which we report silence

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# ── Pre-compute pitch-class mapping for every FFT bin ────────────────────────
freqs = np.fft.rfftfreq(N, 1.0 / SR)
with np.errstate(divide="ignore"):
    midi = 69.0 + 12.0 * np.log2(np.maximum(freqs, 1e-9) / 440.0)
pc = np.mod(np.round(midi).astype(np.int32), 12)

# Restrict to the musical range C2 (~65 Hz) .. B6 (~1976 Hz).
band_mask = ((freqs >= 60.0) & (freqs <= 2100.0)).astype(np.float32)

window = np.hanning(N).astype(np.float32)
buf    = np.zeros(0, dtype=np.float32)
ema    = np.zeros(12, dtype=np.float32)

print("STATUS:READY", flush=True)

try:
    while True:
        raw = sys.stdin.buffer.read(HOP * 2)
        if not raw or len(raw) < HOP * 2:
            break

        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        buf = np.concatenate([buf, samples])
        if len(buf) < N:
            continue
        frame = buf[-N:]
        buf   = buf[-N:]                      # keep only the most recent window

        rms = float(np.sqrt(np.mean(frame * frame)))
        if rms < GATE:
            ema *= 0.6                         # decay quickly during silence
            print("CHROMA:" + ",".join(f"{v:.3f}" for v in ema), flush=True)
            continue

        spec   = np.abs(np.fft.rfft(frame * window)) * band_mask
        chroma = np.zeros(12, dtype=np.float32)
        np.add.at(chroma, pc, spec)

        s = float(chroma.sum())
        if s > 0.0:
            chroma /= s

        ema = ALPHA * chroma + (1.0 - ALPHA) * ema

        order = np.argsort(-ema)
        top3  = ",".join(NOTE_NAMES[i] for i in order[:3])
        print("CHROMA:" + ",".join(f"{v:.3f}" for v in ema), flush=True)
        print("TOP:" + top3, flush=True)
except (BrokenPipeError, KeyboardInterrupt):
    pass
