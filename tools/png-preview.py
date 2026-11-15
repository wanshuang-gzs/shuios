#!/usr/bin/env python3
"""ASCII preview + colour histogram for a PNG (pure stdlib, RGB/RGBA 8-bit).

    python tools/png-preview.py file.png [cols]
"""
import sys
import zlib


def load_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    i = 8
    w = h = bitdepth = colortype = None
    idat = bytearray()
    while i < len(data):
        length = int.from_bytes(data[i:i + 4], 'big')
        tag = data[i + 4:i + 8]
        payload = data[i + 8:i + 8 + length]
        i += 12 + length
        if tag == b'IHDR':
            w = int.from_bytes(payload[0:4], 'big')
            h = int.from_bytes(payload[4:8], 'big')
            bitdepth = payload[8]
            colortype = payload[9]
        elif tag == b'IDAT':
            idat += payload
        elif tag == b'IEND':
            break
    assert bitdepth == 8, 'only 8-bit png'
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colortype]
    raw = zlib.decompress(bytes(idat))
    stride = w * channels
    prev = bytearray(stride)
    rows = []
    pos = 0
    for _ in range(h):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if f == 1:
            for x in range(stride):
                line[x] = (line[x] + (line[x - channels] if x >= channels else 0)) & 0xFF
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif f == 3:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif f == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = prev[x]
                c = prev[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
        rows.append(bytes(line))
        prev = line
    return w, h, channels, rows


def px_at(rows, w, channels, x, y):
    row = rows[y]
    o = x * channels
    return row[o], row[o + 1], row[o + 2]


def main():
    path = sys.argv[1]
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    w, h, ch, rows = load_png(path)
    print('%s: %dx%d, channels=%d' % (path, w, h, ch))

    # histogram over a coarse grid
    hist = {}
    for y in range(0, h, max(1, h // 200)):
        for x in range(0, w, max(1, w // 200)):
            r, g, b = px_at(rows, w, ch, x, y)
            key = '#%02x%02x%02x' % (r // 4 * 4, g // 4 * 4, b // 4 * 4)
            hist[key] = hist.get(key, 0) + 1
    total = sum(hist.values())
    print('top colours (coarse):')
    for c, n in sorted(hist.items(), key=lambda kv: -kv[1])[:6]:
        print('   %s  %.1f%%' % (c, 100.0 * n / total))

    # ascii preview
    ramp = ' .:-=+*#%@'
    aspect = 2.1
    grid_h = max(6, int(cols / aspect * h / w))
    print('--- ascii preview ---')
    for gy in range(grid_h):
        line = []
        for gx in range(cols):
            x = min(w - 1, int((gx + 0.5) * w / cols))
            y = min(h - 1, int((gy + 0.5) * h / grid_h))
            r, g, b = px_at(rows, w, ch, x, y)
            lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            line.append(ramp[min(len(ramp) - 1, int(lum * len(ramp)))])
        print('|' + ''.join(line) + '|')


if __name__ == '__main__':
    main()
