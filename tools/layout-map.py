#!/usr/bin/env python3
"""Classify each grid cell of a frame into a UI layer and print a map.

Because the model here cannot look at images, this prints a spatial layout
instead: W=wallpaper S=store window T=store tile F=terminal B=bar A=accent
t=light text ?=other

    python tools/layout-map.py shot.ppm [cols]
"""
import sys

PALETTE = [
    ('W', (0x12, 0x1c, 0x28)),   # wallpaper mid tone
    ('W', (0x0a, 0x12, 0x1b)),
    ('W', (0x17, 0x22, 0x2e)),
    ('S', (0x0e, 0x16, 0x20)),   # store window background
    ('S', (0x0b, 0x14, 0x20)),   # store header bar
    ('T', (0x16, 0x22, 0x2e)),   # store tile
    ('T', (0x1b, 0x2b, 0x39)),   # tile hover
    ('F', (0x0e, 0x16, 0x20)),   # foot background
    ('B', (0x0d, 0x16, 0x20)),   # swaybar
    ('A', (0x2d, 0xae, 0xd9)),   # accent
    ('A', (0x2d, 0x6a, 0x8a)),   # accent dim
    ('t', (0xd8, 0xe0, 0xe8)),   # light text
    ('t', (0xcf, 0xe0, 0xea)),
    ('k', (0x07, 0x13, 0x1a)),   # dark text on accent button
]


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


def classify(rgb):
    best, dist = '?', 1 << 30
    for tag, p in PALETTE:
        d = sum((rgb[k] - p[k]) ** 2 for k in range(3))
        if d < dist:
            dist, best = d, tag
    return best if dist < 1400 else '?'


def main():
    path = sys.argv[1]
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 78
    w, h, px = load_ppm(path)
    rows = max(8, int(cols * h / w / 2.1))
    print('%s  %dx%d' % (path, w, h))
    for gy in range(rows):
        line = []
        for gx in range(cols):
            x = min(w - 1, int((gx + 0.5) * w / cols))
            y = min(h - 1, int((gy + 0.5) * h / rows))
            i = (y * w + x) * 3
            line.append(classify((px[i], px[i + 1], px[i + 2])))
        print('|' + ''.join(line) + '|')


if __name__ == '__main__':
    main()
