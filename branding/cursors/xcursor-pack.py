#!/usr/bin/env python3
"""Pack PNG frames into one XCursor file (stdlib only; replaces xcursorgen, which is not installed here).

usage: xcursor-pack.py OUT --hotspot HX HY --delay MS SIZE:PNG [SIZE:PNG ...]

HX/HY are in the 32 px design grid and scale with SIZE. Frames of one size are written in the order given
(animation order). PNGs must be 8-bit RGBA, non-interlaced (what rsvg-convert writes).
"""
import math
import os
import struct
import sys
import zlib
import multiprocessing
from concurrent.futures import ProcessPoolExecutor

IMAGE_TYPE = 0xFFFD0002


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, width, height = 8, b"", 0, 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if (depth, ctype, interlace) != (8, 6, 0):
                raise SystemExit(f"{path}: need 8-bit RGBA non-interlaced PNG")
        elif kind == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    stride = width * 4
    out = bytearray()
    prev = bytearray(stride)
    i = 0
    for _ in range(height):
        ftype = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b = prev[x]
            c = prev[x - 4] if x >= 4 else 0
            if ftype == 1:
                line[x] = (line[x] + a) & 255
            elif ftype == 2:
                line[x] = (line[x] + b) & 255
            elif ftype == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
            elif ftype != 0:
                raise SystemExit(f"{path}: bad PNG filter {ftype}")
        out += line
        prev = line
    return width, height, bytes(out)


def argb_premultiplied(rgba):
    # XCursor pixels are premultiplied ARGB, stored little-endian (B, G, R, A).
    alpha = rgba[3::4]
    out = bytearray(len(rgba))
    out[3::4] = alpha
    for src, dst in ((2, 0), (1, 1), (0, 2)):
        out[dst::4] = bytes([(c * a + 127) // 255 for c, a in zip(rgba[src::4], alpha)])
    return bytes(out)


def main(argv):
    if len(argv) < 7 or argv[2] != "--hotspot" or argv[5] != "--delay":
        raise SystemExit(__doc__)
    out_path, hx, hy, delay = argv[1], float(argv[3]), float(argv[4]), int(argv[6])
    specs = argv[7:]
    chunks = []
    # Animated cursors have many large frames: decode them on all cores.
    if len(specs) > 8:
        with ProcessPoolExecutor(os.cpu_count() or 2, mp_context=multiprocessing.get_context("fork")) as pool:
            decoded = list(pool.map(read_png, [s.split(":", 1)[1] for s in specs], chunksize=4))
    else:
        decoded = [read_png(s.split(":", 1)[1]) for s in specs]
    for spec, (width, height, rgba) in zip(specs, decoded):
        size = int(spec.split(":", 1)[0])
        # Round half up, as libhyprcursor does (Python's round() rounds half to even: (8,4) against (8,5) at 48 px).
        xhot = min(width - 1, max(0, math.floor(hx * size / 32 + 0.5)))
        yhot = min(height - 1, max(0, math.floor(hy * size / 32 + 0.5)))
        header = struct.pack("<9I", 36, IMAGE_TYPE, size, 1, width, height, xhot, yhot, delay)
        chunks.append((size, header + argb_premultiplied(rgba)))
    if not chunks:
        raise SystemExit("no frames")
    toc_pos = 16 + 12 * len(chunks)
    toc, body, pos = b"", b"", toc_pos
    for size, chunk in chunks:
        toc += struct.pack("<3I", IMAGE_TYPE, size, pos)
        body += chunk
        pos += len(chunk)
    with open(out_path, "wb") as f:
        f.write(b"Xcur" + struct.pack("<3I", 16, 0x10000, len(chunks)) + toc + body)


if __name__ == "__main__":
    main(sys.argv)
