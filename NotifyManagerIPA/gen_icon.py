# 生成 120x120 蓝色占位 PNG 作为 App 图标
import struct, zlib, sys

out = sys.argv[1] if len(sys.argv) > 1 else 'AppIcon.png'
w, h = 120, 120
r, g, b = 64, 124, 220

raw = b''
for y in range(h):
    raw += b'\x00' + bytes([r, g, b, 255]) * w

def chunk(ct, data):
    c = ct + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(raw)) +
       chunk(b'IEND', b''))

with open(out, 'wb') as f:
    f.write(png)
print(f'Icon generated: {out} ({len(png)} bytes)')