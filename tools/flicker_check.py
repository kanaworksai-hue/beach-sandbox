"""Frame-to-frame difference check for recorded shots (flicker / jump detector).
python tools/flicker_check.py captures/rec_<shot> ...
Prints median / p99 / max mean-abs-difference (0..255, 240p greyscale) and the frames of
spikes > 3x the local median: a smooth camera move gives a flat curve, a pop or flicker a spike.
"""
import glob
import sys

import numpy as np
from PIL import Image

for d in sys.argv[1:]:
    files = sorted(glob.glob(d + "/f_*.jpg"))
    prev = None
    diffs = []
    for f in files:
        im = np.asarray(Image.open(f).convert("L").resize((426, 240)), dtype=np.float32)
        if prev is not None:
            diffs.append(float(np.abs(im - prev).mean()))
        prev = im
    a = np.array(diffs)
    spikes = []
    for i in range(len(a)):
        lo, hi = max(0, i - 15), min(len(a), i + 16)
        med = np.median(a[lo:hi])
        if a[i] > 3.0 * max(med, 0.3):
            spikes.append((i + 1, round(a[i], 2), round(float(med), 2)))
    print("%s frames=%d median=%.2f p99=%.2f max=%.2f spikes=%s" % (
        d, len(files), np.median(a), np.percentile(a, 99), a.max(), spikes[:10]))
