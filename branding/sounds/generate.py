#!/usr/bin/env python3
"""Grassfield's own sound set (ADR-0047 part B): writes the WAV files of the `grassfield` sound theme.

Standard library only (wave, math, struct). Every sound is synthesised here: sums of sine partials with exponential
envelopes, plucked strings (Karplus-Strong) and filtered noise from a fixed-seed generator, so the output is the same on
every run. Nothing is sampled, traced or imitated from another system's sounds. 44.1 kHz, mono, 16-bit PCM.

Usage: generate.py            write branding/sounds/grassfield/stereo/*.wav
       generate.py --check    exit 1 when a committed file is missing or differs (by more than 2 LSB per sample: the
                              platform's libm may round a sine differently in its last bit)
       generate.py --list     print the file names
Licence: MIT (the script and the sounds it writes are the project's own).
"""
import math
import pathlib
import struct
import sys
import wave

RATE = 44100
PEAK = 0.70  # -3 dBFS
LOUDNESS = 0.18  # the highest mean (RMS) level of a sound
OUT = pathlib.Path(__file__).resolve().parent / "grassfield" / "stereo"


# ---- Building blocks ---------------------------------------------------------------------------------------------------

class Noise:
    """A deterministic white noise in [-1, 1] (a 32-bit linear congruential generator)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self):
        self.state = (1664525 * self.state + 1013904223) & 0xFFFFFFFF
        return self.state / 2147483647.5 - 1.0


def silence(seconds):
    return [0.0] * int(round(seconds * RATE))


def mix(*tracks):
    """Tracks as (offset in seconds, samples, gain)."""
    length = max(int(round(off * RATE)) + len(s) for off, s, _ in tracks)
    out = [0.0] * length
    for off, samples, gain in tracks:
        start = int(round(off * RATE))
        for i, v in enumerate(samples):
            out[start + i] += v * gain
    return out


def mallet(freq, seconds, partials, attack=0.002, vibrato=0.0):
    """A struck tone: partials as (frequency ratio, amplitude, decay per second); a short linear attack."""
    n = int(round(seconds * RATE))
    out = []
    for i in range(n):
        t = i / RATE
        env_a = min(1.0, t / attack) if attack > 0 else 1.0
        wobble = 1.0 + vibrato * math.sin(2 * math.pi * 5.5 * t)
        v = 0.0
        for ratio, amp, decay in partials:
            v += amp * math.exp(-decay * t) * math.sin(2 * math.pi * freq * ratio * wobble * t)
        out.append(v * env_a)
    return out


def glide(f0, f1, seconds, decay, glide_time):
    """A sine whose pitch moves from f0 to f1 (exponentially, over glide_time) and fades."""
    n = int(round(seconds * RATE))
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        k = min(1.0, t / glide_time)
        f = f0 * (f1 / f0) ** k
        phase += 2 * math.pi * f / RATE
        attack = min(1.0, t / 0.001)
        out.append(attack * math.exp(-decay * t) * math.sin(phase))
    return out


def pluck(freq, seconds, seed, damping=0.996, brightness=0.5):
    """A plucked string (Karplus-Strong): a noise burst in a delay line averaged on each pass."""
    noise = Noise(seed)
    period = max(2, int(round(RATE / freq)))
    line = [noise.next() for _ in range(period)]
    # A darker excitation for a softer pluck, without a DC offset.
    for i in range(1, period):
        line[i] = brightness * line[i] + (1 - brightness) * line[i - 1]
    mean = sum(line) / period
    line = [v - mean for v in line]
    out = []
    n = int(round(seconds * RATE))
    idx = 0
    for _ in range(n):
        a = line[idx]
        b = line[(idx + 1) % period]
        line[idx] = damping * 0.5 * (a + b)
        out.append(a)
        idx = (idx + 1) % period
    return out


def filtered_noise(seconds, seed, cutoff_start, cutoff_end, envelope, highpass=60.0):
    """Noise through a one-pole low-pass whose cutoff glides (exponentially) and a one-pole high-pass; `envelope(t)`."""
    noise = Noise(seed)
    n = int(round(seconds * RATE))
    out = []
    low = 0.0
    prev_in = 0.0
    prev_out = 0.0
    rc_hp = 1.0 / (2 * math.pi * highpass)
    alpha_hp = rc_hp / (rc_hp + 1.0 / RATE)
    for i in range(n):
        t = i / RATE
        k = t / seconds
        cutoff = cutoff_start * (cutoff_end / cutoff_start) ** k
        alpha = 1.0 - math.exp(-2 * math.pi * cutoff / RATE)
        low += alpha * (noise.next() - low)
        hp = alpha_hp * (prev_out + low - prev_in)
        prev_in, prev_out = low, hp
        out.append(hp * envelope(t))
    return out


def finish(samples, head=0.0008, tail=0.03):
    """Remove the mean, normalise to PEAK, fade in over `head` and out over `tail` (no click at either end)."""
    mean = sum(samples) / len(samples)
    centred = [v - mean for v in samples]
    peak = max(abs(v) for v in centred) or 1.0
    rms = math.sqrt(sum(v * v for v in centred) / len(centred)) or 1.0
    # As loud as the peak allows, but no louder on average than LOUDNESS (a sustained tone is not louder than a struck one).
    out = [v * min(PEAK / peak, LOUDNESS / rms) for v in centred]
    fade_in = max(1, int(head * RATE))
    for i in range(min(fade_in, len(out))):
        out[i] *= i / fade_in
    fade = max(1, int(tail * RATE))
    for i in range(min(fade, len(out))):
        out[len(out) - 1 - i] *= (i / fade) ** 2
    return out


def pcm(samples):
    return b"".join(struct.pack("<h", max(-32767, min(32767, int(round(v * 32767))))) for v in samples)


# ---- The sounds ----------------------------------------------------------------------------------------------------------

def note(name):
    """Equal temperament, A4 = 440 Hz: "C6", "F#5"."""
    steps = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((steps[pitch] + 12 * (octave - 4)) / 12)


MARIMBA = [(1.0, 1.0, 9.0), (3.93, 0.22, 26.0), (9.2, 0.05, 60.0)]
BELL = [(1.0, 1.0, 4.5), (2.76, 0.45, 7.0), (5.40, 0.22, 11.0), (8.93, 0.10, 17.0)]


def meadow():
    # Two soft mallet notes, a fourth apart, rising.
    return finish(mix((0.0, mallet(note("G5"), 0.42, MARIMBA), 0.8), (0.075, mallet(note("C6"), 0.45, MARIMBA), 1.0)))


def dewdrop():
    # A drop: a sine falling an octave fast, then a smaller second one.
    return finish(mix((0.0, glide(1700.0, 820.0, 0.22, 16.0, 0.05), 1.0), (0.11, glide(2100.0, 1150.0, 0.16, 22.0, 0.04), 0.45)))


def reed():
    # A short breathy reed tone: odd harmonics, a slow attack and a little vibrato.
    partials = [(1.0, 1.0, 5.0), (3.0, 0.32, 7.0), (5.0, 0.12, 10.0)]
    body = mallet(note("A5"), 0.38, partials, attack=0.025, vibrato=0.004)
    breath = filtered_noise(0.38, 7, 3000.0, 1500.0, lambda t: 0.06 * math.exp(-9 * t))
    return finish(mix((0.0, body, 1.0), (0.0, breath, 1.0)))


def lantern():
    # One clear bell partial set (inharmonic ratios of a struck bell), long and quiet decay.
    return finish(mallet(note("E5"), 0.9, BELL, attack=0.001))


def ember():
    # Two warm low notes falling a fifth, a soft felt mallet.
    felt = [(1.0, 1.0, 8.0), (2.0, 0.18, 14.0), (3.0, 0.05, 20.0)]
    return finish(mix((0.0, mallet(note("D5"), 0.32, felt, attack=0.006), 1.0), (0.09, mallet(note("G4"), 0.4, felt, attack=0.006), 0.9)))


def thistle():
    # Three quick plucks going up a major triad.
    return finish(mix((0.0, pluck(note("G5"), 0.3, 11), 0.8), (0.05, pluck(note("B5"), 0.3, 12), 0.8), (0.10, pluck(note("D6"), 0.34, 13), 1.0)))


def screen_capture():
    # Two dry clicks of filtered noise 70 ms apart with a muted low body: an abstract shutter.
    def click(seed, bright):
        return filtered_noise(0.05, seed, bright, 1200.0, lambda t: math.exp(-110 * t), highpass=400.0)
    body = mallet(180.0, 0.08, [(1.0, 1.0, 60.0)], attack=0.001)
    return finish(mix((0.0, click(21, 9000.0), 1.0), (0.0, body, 0.35), (0.07, click(22, 7000.0), 0.8), (0.07, body, 0.25)))


def trash_empty():
    # A whoosh: noise whose brightness sweeps down while it swells and fades.
    def env(t):
        return math.sin(math.pi * min(1.0, t / 0.55)) ** 1.5
    return finish(filtered_noise(0.55, 31, 7000.0, 350.0, env, highpass=120.0))


def volume_change():
    # A tiny soft tick with a slight pitch drop.
    return finish(glide(1250.0, 900.0, 0.06, 70.0, 0.02))


def power_plug():
    # A calm two-note chime going up a fifth.
    soft = [(1.0, 1.0, 6.0), (2.0, 0.12, 12.0)]
    return finish(mix((0.0, mallet(note("C5"), 0.5, soft, attack=0.004), 0.8), (0.11, mallet(note("G5"), 0.55, soft, attack=0.004), 1.0)))


def dock_remove():
    # A soft puff: a short burst of airy noise opening up then fading.
    def env(t):
        return (1 - math.exp(-t / 0.008)) * math.exp(-t * 11)
    return finish(filtered_noise(0.32, 41, 900.0, 5000.0, env, highpass=200.0))


SOUNDS = {
    "grassfield-alert-meadow.wav": meadow,
    "grassfield-alert-dewdrop.wav": dewdrop,
    "grassfield-alert-reed.wav": reed,
    "grassfield-alert-lantern.wav": lantern,
    "grassfield-alert-ember.wav": ember,
    "grassfield-alert-thistle.wav": thistle,
    "screen-capture.wav": screen_capture,
    "trash-empty.wav": trash_empty,
    "audio-volume-change.wav": volume_change,
    "power-plug.wav": power_plug,
    "grassfield-dock-remove.wav": dock_remove,
}


def write(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm(samples))


def read(path):
    with wave.open(str(path), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            return None
        frames = w.readframes(w.getnframes())
    return struct.unpack("<%dh" % (len(frames) // 2), frames)


def main(argv):
    if argv == ["--list"]:
        print("\n".join(SOUNDS))
        return 0
    if argv == ["--check"]:
        bad = []
        for name, make in SOUNDS.items():
            path = OUT / name
            samples = make()
            want = struct.unpack("<%dh" % len(samples), pcm(samples))
            have = read(path) if path.is_file() else None
            if have is None or len(have) != len(want) or any(abs(a - b) > 2 for a, b in zip(have, want)):
                bad.append(name)
        extra = sorted(p.name for p in OUT.glob("*.wav") if p.name not in SOUNDS)
        for name in bad:
            print("stale or missing: " + name)
        for name in extra:
            print("not generated here: " + name)
        return 1 if bad or extra else 0
    if argv:
        sys.stderr.write(__doc__)
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    for name, make in SOUNDS.items():
        write(OUT / name, make())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
