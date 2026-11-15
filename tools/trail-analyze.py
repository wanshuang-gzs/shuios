#!/usr/bin/env python3
"""Compare two PPM frames and report how much changed (smear detection).

ASCII only on purpose: Windows consoles here default to GBK, so Chinese
output from an inline -c script raises UnicodeEncodeError.
"""
import sys


def load(path):
    data = open(path, 'rb').read()
    parts = data.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def main(a_path, b_path):
    w1, h1, a = load(a_path)
    w2, h2, b = load(b_path)
    n = min(len(a), len(b))
    diff = 0
    xmin, xmax, ymin, ymax = w1, -1, h1, -1
    for i in range(0, n - 2, 3):
        if a[i:i + 3] != b[i:i + 3]:
            diff += 1
            p = i // 3
            x, y = p % w1, p // w1
            if x < xmin:
                xmin = x
            if x > xmax:
                xmax = x
            if y < ymin:
                ymin = y
            if y > ymax:
                ymax = y
    total = w1 * h1
    print('size        : %dx%d' % (w1, h1))
    print('changed px  : %d (%.2f%%)' % (diff, 100.0 * diff / total))
    if xmax >= 0:
        print('changed bbox: x %d..%d  y %d..%d' % (xmin, xmax, ymin, ymax))
    else:
        print('changed bbox: none')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
