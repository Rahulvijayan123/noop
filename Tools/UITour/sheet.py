#!/usr/bin/env python3
"""Lay screenshots side by side into one contact sheet: sheet.py <out.png> <height> <in.png>..."""
import sys
from PIL import Image

out, height, paths = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
shots = [Image.open(p).convert("RGB") for p in paths]
shots = [s.resize((round(s.width * height / s.height), height), Image.LANCZOS) for s in shots]
sheet = Image.new("RGB", (sum(s.width for s in shots) + 8 * (len(shots) - 1), height), "white")
x = 0
for s in shots:
    sheet.paste(s, (x, 0))
    x += s.width + 8
sheet.save(out)
print(out)
