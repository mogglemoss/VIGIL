#!/usr/bin/env python3
"""Strikes the office's two sounds. No samples, no licences, no dependencies.

The Ministry does not chime. It stamps. Both cues are the sound of paperwork
being dealt with: dry, mechanical, over before you have finished hearing them.

  latch.wav  — the record is opened. A drawer catching. 70 ms.
  stamp.wav  — the record is filed. Rubber on paper on desk. 150 ms.
"""
import math, random, struct, wave, os

RATE = 44100
random.seed(11)   # the same impression every time


def lowpass(xs, cutoff):
    a = (2 * math.pi * cutoff / RATE) / (2 * math.pi * cutoff / RATE + 1)
    out, y = [], 0.0
    for x in xs:
        y += a * (x - y)
        out.append(y)
    return out


def render(samples, path, peak=0.5):
    high = max(abs(s) for s in samples) or 1.0
    scaled = [int(max(-1, min(1, s / high * peak)) * 32767) for s in samples]
    with wave.open(path, "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<h", s) for s in scaled))
    print(f"{path}  {len(samples)/RATE*1000:.0f} ms")


def stamp():
    """Rubber hits paper hits desk: a bright contact transient over a low thump."""
    n = int(0.150 * RATE)
    contact = lowpass([random.uniform(-1, 1) for _ in range(n)], 2600)
    out = []
    for i in range(n):
        t = i / RATE
        s  = contact[i] * math.exp(-t / 0.0045) * 1.0      # the impression
        s += math.sin(2 * math.pi * 108 * t) * math.exp(-t / 0.030) * 0.85   # the block
        s += math.sin(2 * math.pi * 216 * t) * math.exp(-t / 0.016) * 0.28   # its overtone
        s *= min(1.0, t / 0.0004)                          # no click on entry
        out.append(s)
    return out


def latch():
    """A drawer catching. Higher, drier, and quicker to be done."""
    n = int(0.070 * RATE)
    tick = lowpass([random.uniform(-1, 1) for _ in range(n)], 5200)
    out = []
    for i in range(n):
        t = i / RATE
        s  = tick[i] * math.exp(-t / 0.0016) * 1.0
        s += math.sin(2 * math.pi * 1750 * t) * math.exp(-t / 0.010) * 0.35
        s += math.sin(2 * math.pi * 620 * t) * math.exp(-t / 0.018) * 0.22
        s *= min(1.0, t / 0.0003)
        out.append(s)
    return out


here = os.path.dirname(os.path.abspath(__file__))
render(stamp(), os.path.join(here, "stamp.wav"), peak=0.5)
render(latch(), os.path.join(here, "latch.wav"), peak=0.38)
