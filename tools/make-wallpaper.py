#!/usr/bin/env python3
"""Generate the shuios wallpaper (pure stdlib PNG writer, no PIL).

Design: macOS Sonoma style — bright diagonal gradient
(blue #5B8DEF -> purple #9B7BF0 -> pink #E08BC0) with a soft light bloom.
The wallpaper must be BRIGHT: frosted-glass (blur) panels only read as
glass when there is a luminous backdrop shining through them.

    python tools/make-wallpaper.py 1280x800 out.png
"""
import math
import struct
import sys
import zlib

C1 = (0x5B, 0x8D, 0xEF)   # blue,  top-left
C2 = (0x9B, 0x7B, 0xF0)   # purple, middle
C3 = (0xE0, 0x8B, 0xC0)   # pink,  bottom-right


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def add(c, rgb, k):
    return tuple(min(255, int(c[i] + rgb[i] * k)) for i in range(3))


def smooth(t):
    return t * t * (3.0 - 2.0 * t)


def render(w, h):
    px = bytearray()
    for y in range(h):
        fy = y / h
        for x in range(w):
            # 对角渐变：左上 → 右下，smoothstep 让过渡更柔
            t = smooth((x / w + fy) * 0.5)
            c = lerp(C1, C2, t * 2) if t < 0.5 else lerp(C2, C3, (t - 0.5) * 2)
            # 柔光斑：右上偏亮 + 左下一点点暖光，增加通透感
            dx = (x - w * 0.74) / w
            dy = (y - h * 0.26) / h
            g = max(0.0, 1.0 - (dx * dx * 2.0 + dy * dy * 3.0))
            c = add(c, (255, 250, 244), 0.20 * g * g)
            dx2 = (x - w * 0.16) / w
            dy2 = (y - h * 0.86) / h
            g2 = max(0.0, 1.0 - (dx2 * dx2 * 2.6 + dy2 * dy2 * 3.4))
            c = add(c, (255, 214, 235), 0.10 * g2 * g2)
            px += bytes(c)
    return bytes(px)


def chunk(tag, payload):
    return (struct.pack('>I', len(payload)) + tag + payload +
            struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))


def main():
    size = sys.argv[1] if len(sys.argv) > 1 else '1280x800'
    out = sys.argv[2] if len(sys.argv) > 2 else 'wallpaper.png'
    w, h = (int(v) for v in size.lower().split('x'))
    rgb = render(w, h)
    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) +
           chunk(b'IEND', b''))
    open(out, 'wb').write(png)
    print('%s: %dx%d, %d bytes' % (out, w, h, len(png)))


if __name__ == '__main__':
    main()
