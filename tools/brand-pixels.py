#!/usr/bin/env python3
"""Count how many pixels match each brand colour in a PPM frame.

Used to confirm the themed UI is actually on screen (bar / store / tiles /
accent buttons / wallpaper) without being able to look at the image.

    python tools/brand-pixels.py shot.ppm
"""
import sys

BRAND = [
    ('bar #0d1620', (0x0d, 0x16, 0x20)),
    ('store bg #0c1420', (0x0c, 0x14, 0x20)),
    ('store header #0b1420', (0x0b, 0x14, 0x20)),
    ('tile #16222e', (0x16, 0x22, 0x2e)),
    ('accent #2daed9', (0x2d, 0xae, 0xd9)),
    ('accent dim #2d6a8a', (0x2d, 0x6a, 0x8a)),
    ('badge #1d5a7a', (0x1d, 0x5a, 0x7a)),
    ('text #d8e0e8', (0xd8, 0xe0, 0xe8)),
    ('foot bg #0e1620', (0x0e, 0x16, 0x20)),
    ('wallpaper #0a121b', (0x0a, 0x12, 0x1b)),
    ('wallpaper #17222e', (0x17, 0x22, 0x2e)),
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


def main():
    path = sys.argv[1]
    w, h, px = load_ppm(path)
    total = w * h
    print('%s  %dx%d  (%d px)' % (path, w, h, total))
    for label, rgb in BRAND:
        n = 0
        for i in range(0, total * 3, 3):
            if px[i] == rgb[0] and px[i + 1] == rgb[1] and px[i + 2] == rgb[2]:
                n += 1
        if n:
            print('  %-22s %8d px  %5.2f%%' % (label, n, 100.0 * n / total))
        else:
            print('  %-22s %8d px  (none)' % (label, n))


if __name__ == '__main__':
    main()
