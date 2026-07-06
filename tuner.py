#!/usr/bin/env python3
"""tuner.py — Real-time monophonic pitch detector for Quickshell.

Reads raw stereo PCM (s16le @ 44100 Hz) from stdin (microphone via parec) and
sums the two channels to mono — summing (rather than averaging) keeps the full
level of whichever hardware input the mic is on, instead of attenuating it by
mixing in silent channels. Estimates the fundamental frequency with an
FFT-based autocorrelation and prints one line per analysis frame:

    STATUS:READY            — on startup
    PITCH:<hz>              — detected fundamental in Hz, or 0 when unvoiced

Note/cents conversion is done on the QML side.
"""

import sys
import numpy as np

SR    = 44100
N     = 4096          # analysis window (~93 ms) — several periods of low notes
HOP   = 512           # advance per frame (~86 fps) — heavy overlap → fluid
FMIN  = 55.0          # A1
FMAX  = 1500.0        # ~F#6
GATE  = 0.002         # RMS gate below which we report silence
CONF  = 0.25          # min normalized autocorrelation peak to accept a pitch
ALPHA = 0.4           # EMA smoothing factor on the emitted frequency

lag_min = max(1, int(SR / FMAX))
lag_max = int(SR / FMIN)

window = np.hanning(N).astype(np.float32)
buf    = np.zeros(0, dtype=np.float32)
ema_f  = 0.0

# Zero-padded FFT length for linear (non-circular) autocorrelation.
nfft = 1
while nfft < 2 * N:
    nfft *= 2

print("STATUS:READY", flush=True)

try:
    while True:
        raw = sys.stdin.buffer.read(HOP * 2 * 2)   # HOP frames × 2 ch × 2 bytes
        if not raw or len(raw) < HOP * 2 * 2:
            break

        stereo  = np.frombuffer(raw, dtype=np.int16).astype(np.float32).reshape(-1, 2)
        samples = stereo.sum(axis=1) / 32768.0     # sum L+R → mono, no attenuation
        buf = np.concatenate([buf, samples])
        if len(buf) < N:
            continue
        frame = buf[-N:]
        buf   = buf[-N:]                       # keep only the most recent window

        frame = frame - float(frame.mean())
        rms = float(np.sqrt(np.mean(frame * frame)))
        if rms < GATE:
            ema_f = 0.0
            print("PITCH:0", flush=True)
            continue

        # Autocorrelation via FFT (Wiener–Khinchin).
        spec = np.fft.rfft(frame * window, nfft)
        acf  = np.fft.irfft(spec * np.conj(spec))[:N]
        if acf[0] <= 0.0:
            ema_f = 0.0
            print("PITCH:0", flush=True)
            continue

        seg = acf[lag_min:lag_max]
        if seg.size == 0:
            print("PITCH:0", flush=True)
            continue
        peak = int(np.argmax(seg)) + lag_min
        if acf[peak] / acf[0] < CONF:          # not periodic enough → unvoiced
            ema_f = 0.0
            print("PITCH:0", flush=True)
            continue

        # Parabolic interpolation around the peak for sub-sample precision.
        if 1 <= peak < N - 1:
            a, b, c = acf[peak - 1], acf[peak], acf[peak + 1]
            denom = a - 2.0 * b + c
            shift = 0.5 * (a - c) / denom if denom != 0.0 else 0.0
        else:
            shift = 0.0
        period = peak + shift
        freq   = SR / period if period > 0.0 else 0.0

        if not (FMIN <= freq <= FMAX):
            print("PITCH:0", flush=True)
            continue

        ema_f = freq if ema_f == 0.0 else ALPHA * freq + (1.0 - ALPHA) * ema_f
        print(f"PITCH:{ema_f:.2f}", flush=True)
except (BrokenPipeError, KeyboardInterrupt):
    pass
