#!/usr/bin/env python3
"""分析 QEMU 截的 PPM：颜色直方图 + ASCII 亮度预览，用于无图形环境下确认画面内容。"""
import collections
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/shot.ppm"
data = open(path, "rb").read()
# P6 头：magic\n W H\n maxval\n <binary>
idx = 0
fields = []
while len(fields) < 4:
    while data[idx:idx + 1].isspace():
        idx += 1
    if data[idx:idx + 1] == b"#":
        while data[idx:idx + 1] != b"\n":
            idx += 1
        continue
    start = idx
    while not data[idx:idx + 1].isspace():
        idx += 1
    fields.append(data[start:idx])
idx += 1
w, h = int(fields[1]), int(fields[2])
px = data[idx:]

print(f"尺寸 {w}x{h}，像素数据 {len(px)} 字节")

# 颜色直方图（全采样）
cnt = collections.Counter()
for y in range(0, h, 3):
    base = y * w * 3
    for x in range(0, w, 3):
        i = base + x * 3
        cnt[px[i:i + 3]] += 1
total = sum(cnt.values())
print(f"采样 {total} 像素，唯一颜色 {len(cnt)}")
for c, n in cnt.most_common(10):
    print(f"   #{c[0]:02x}{c[1]:02x}{c[2]:02x}  {100.0 * n / total:5.1f}%")

bg = cnt.most_common(1)[0][0]
diff = sum(n for c, n in cnt.items() if c != bg)
print(f"非背景像素占比 {100.0 * diff / total:.2f}%")

# ASCII 预览：每格取平均亮度
cols, rows = 78, 26
print("\n=== ASCII 预览（越亮字符越密）===")
ramp = " .:-=+*#%@"
for r in range(rows):
    line = []
    for c in range(cols):
        x0, x1 = c * w // cols, (c + 1) * w // cols
        y0, y1 = r * h // rows, (r + 1) * h // rows
        acc = 0
        n = 0
        for y in range(y0, y1, max(1, (y1 - y0) // 4)):
            base = y * w * 3
            for x in range(x0, x1, max(1, (x1 - x0) // 4)):
                i = base + x * 3
                acc += (px[i] + px[i + 1] + px[i + 2]) // 3
                n += 1
        v = acc // n if n else 0
        line.append(ramp[min(len(ramp) - 1, v * len(ramp) // 256)])
    print("|" + "".join(line) + "|")
