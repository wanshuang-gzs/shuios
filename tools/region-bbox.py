#!/usr/bin/env python3
"""Report bounding boxes for the dominant colours of a frame.

Used to work out where windows actually ended up (window manager geometry
without needing python on the guest).
    python tools/region-bbox.py shot.ppm 12
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
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    w, h, px = load_ppm(path)
    counts = {}
    boxes = {}
    for y in range(h):
        row = y * w * 3
        for x in range(w):
            i = row + x * 3
            key = (px[i], px[i + 1], px[i + 2])
            counts[key] = counts.get(key, 0) + 1
            b = boxes.get(key)
            if b is None:
                boxes[key] = [x, y, x, y]
            else:
                if x < b[0]: b[0] = x
                if y < b[1]: b[1] = y
                if x > b[2]: b[2] = x
                if y > b[3]: b[3] = y
    print('size %dx%d' % (w, h))
    for c, n in sorted(counts.items(), key=lambda kv: -kv[1])[:top]:
        b = boxes[c]
        print('#%02x%02x%02x %7.2f%%  box x %4d..%4d  y %4d..%4d'
              % (c[0], c[1], c[2], 100.0 * n / (w * h), b[0], b[2], b[1], b[3]))


if __name__ == '__main__':
    main()
