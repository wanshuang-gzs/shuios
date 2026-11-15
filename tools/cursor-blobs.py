#!/usr/bin/env python3
"""Count near-white pixels (mouse cursor fill) and cluster them.

If the cursor leaves a trail, the after-frame contains several arrow-sized
white clusters instead of one.
ASCII-only output (Windows console defaults to GBK).
"""
import sys


def load(path):
    data = open(path, 'rb').read()
    parts = data.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def white_clusters(path):
    w, h, px = load(path)
    mask = [[False] * w for _ in range(h)]
    total = 0
    for y in range(h):
        row = y * w * 3
        for x in range(w):
            i = row + x * 3
            if px[i] > 235 and px[i + 1] > 235 and px[i + 2] > 235:
                mask[y][x] = True
                total += 1
    seen = [[False] * w for _ in range(h)]
    clusters = []
    for y in range(h):
        for x in range(w):
            if not mask[y][x] or seen[y][x]:
                continue
            stack = [(x, y)]
            seen[y][x] = True
            n = 0
            x0 = x1 = x
            y0 = y1 = y
            while stack:
                cx, cy = stack.pop()
                n += 1
                if cx < x0: x0 = cx
                if cx > x1: x1 = cx
                if cy < y0: y0 = cy
                if cy > y1: y1 = cy
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if n >= 60:  # ignore antialiasing specks
                clusters.append((n, x0, y0, x1, y1))
    clusters.sort(reverse=True)
    return total, clusters


def main():
    for path in sys.argv[1:]:
        total, clusters = white_clusters(path)
        print('--- %s' % path)
        print('  near-white px : %d' % total)
        print('  blobs >=60px  : %d' % len(clusters))
        for n, x0, y0, x1, y1 in clusters[:8]:
            print('    %5d px  box (%d,%d)-(%d,%d)  %dx%d'
                  % (n, x0, y0, x1, y1, x1 - x0 + 1, y1 - y0 + 1))


if __name__ == '__main__':
    main()
