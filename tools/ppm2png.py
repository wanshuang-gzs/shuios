#!/usr/bin/env python3
"""把 QEMU 的 PPM 截图转成 PNG（无需第三方库：手写最小 PNG 编码）。"""
import struct
import sys
import zlib


def load_ppm(path):
    data = open(path, 'rb').read()
    assert data[:2] == b'P6', '只支持 P6 二进制 PPM'
    # 头部：P6 / 尺寸 / 最大值，之间可以有注释和空白
    fields, i = [], 2
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
    w, h, _maxv = fields
    return w, h, data[i:i + w * h * 3]


def write_png(path, w, h, rgb):
    raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload +
                struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) +
           chunk(b'IEND', b''))
    open(path, 'wb').write(png)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('用法: ppm2png.py <输入.ppm> <输出.png>')
        sys.exit(2)
    w, h, rgb = load_ppm(sys.argv[1])
    write_png(sys.argv[2], w, h, rgb)
    print(f'{sys.argv[2]}: {w}x{h}')
