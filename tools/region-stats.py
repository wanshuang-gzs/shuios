#!/usr/bin/env python3
"""Region statistics for a PPM frame: pixel count, light pixels, unique colours.

Used to check "did this region actually get drawn" without looking at images.
    python tools/region-stats.py shot.ppm 78,138,634,166 78,170,634,198 ...
"""
import sys


def load_ppm(path):
    data = open(path, 'rb').read()
    assert data[:2] == b'P6'
    i, fields = 2, []
    while len(fields) < 3:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b'#':
            while data[i:i + 1] not in (b'\n', b''):
                i += 1
            continue
        start = i
        while not data[i:i + 1].isspace():
            i += 1
        fields.append(int(data[start:i]))
    i += 1
    w, h, _ = fields
    return w, h, data[i:i + w * h * 3]


def main():
    path = sys.argv[1]
    w, h, px = load_ppm(path)
    print('%s  %dx%d' % (path, w, h))
    for spec in sys.argv[2:]:
        x0, y0, x1, y1 = (int(v) for v in spec.split(','))
        x1 = min(x1, w)
        y1 = min(y1, h)
        total = light = 0
        colors = set()
        for y in range(y0, y1):
            row = y * w * 3
            for x in range(x0, x1):
                i = row + x * 3
                r, g, b = px[i], px[i + 1], px[i + 2]
                total += 1
                colors.add((r, g, b))
                if r > 140 and g > 140 and b > 140:
                    light += 1
        pct = (100.0 * light / total) if total else 0.0
        print('  region (%d,%d)-(%d,%d): %6d px, light %5d (%.1f%%), colours %d'
              % (x0, y0, x1, y1, total, light, pct, len(colors)))


if __name__ == '__main__':
    main()
