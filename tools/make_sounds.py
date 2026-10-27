"""Génère les effets sonores de VYRO (originaux, créés par synthèse : aucun droit à payer).
Usage : python3 tools/make_sounds.py  ->  écrit VYRO-Sources/Sounds/sfx_*.wav"""
import numpy as np, wave, os
SR = 44100
rng = np.random.default_rng(7)
out = os.path.join(os.path.dirname(__file__), "..", "VYRO-Sources", "Sounds")

def t(d): return np.arange(int(SR * d)) / SR
def env_exp(x, d, k): return np.exp(-k * x / d)
def lowpass(x, a):
    y = np.zeros_like(x); s = 0.0
    for i, v in enumerate(x): s += a * (v - s); y[i] = s
    return y
def bandsweep(noise, f0, f1, d):
    # bruit filtré par un passe-bas dont la fréquence glisse de f0 à f1
    n = len(noise); y = np.zeros(n); s1 = s2 = 0.0
    fc = np.geomspace(f0, f1, n)
    for i in range(n):
        a = 1 - np.exp(-2 * np.pi * fc[i] / SR)
        s1 += a * (noise[i] - s1); s2 += a * (s1 - s2); y[i] = s1 - s2
    return y
def norm(x, peak=0.9):
    x = x - np.mean(x); return x / (np.max(np.abs(x)) + 1e-9) * peak
def fade(x, a=0.005, b=0.02):
    n = len(x); na, nb = int(SR * a), int(SR * b)
    x[:na] *= np.linspace(0, 1, na); x[-nb:] *= np.linspace(1, 0, nb); return x
def save(name, x):
    x = np.clip(fade(norm(x)), -1, 1)
    with wave.open(os.path.join(out, f"sfx_{name}.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())

# 1. whoosh : bruit qui monte puis redescend
d = 0.7; x = t(d); n = rng.standard_normal(len(x))
sw = bandsweep(n, 300, 5000, d) * np.sin(np.pi * x / d) ** 2
save("whoosh", sw)
# 2. whoosh rapide
d = 0.35; x = t(d); n = rng.standard_normal(len(x))
save("whoosh_fast", bandsweep(n, 600, 7000, d) * np.sin(np.pi * x / d) ** 1.5)
# 3. impact : chute de fréquence + claquer
d = 0.9; x = t(d)
f = 45 + 140 * np.exp(-x * 14); ph = 2 * np.pi * np.cumsum(f) / SR
body = np.sin(ph) * env_exp(x, d, 6)
click = lowpass(rng.standard_normal(len(x)), 0.3) * env_exp(x, d, 70) * 0.7
save("impact", body + click)
# 4. basse (bass drop) : sinus grave qui descend
d = 1.3; x = t(d)
f = 38 + 70 * np.exp(-x * 5); ph = 2 * np.pi * np.cumsum(f) / SR
save("bass", (np.sin(ph) + 0.25 * np.sin(2 * ph)) * env_exp(x, d, 3))
# 5. riser : tension qui monte (finit au moment de l'impact)
d = 1.6; x = t(d); n = rng.standard_normal(len(x))
f = np.geomspace(200, 1800, len(x)); ph = 2 * np.pi * np.cumsum(f) / SR
r = bandsweep(n, 400, 6000, d) * 0.9 + np.sin(ph) * 0.35 + np.sin(ph * 1.5) * 0.2
save("riser", r * (x / d) ** 2)
# 6. glitch : rafale de bips numériques
d = 0.32; x = t(d); y = np.zeros(len(x)); pos = 0
while pos < len(x):
    ln = int(SR * rng.uniform(0.012, 0.045)); fr = rng.choice([440, 880, 1320, 2200, 3300])
    seg = np.sign(np.sin(2 * np.pi * fr * np.arange(ln) / SR)); y[pos:pos+ln] += seg[:len(y)-pos] * rng.uniform(0.3, 1)
    pos += ln + int(SR * rng.uniform(0.0, 0.02))
save("glitch", y * env_exp(x, d, 2))
print("ok")
