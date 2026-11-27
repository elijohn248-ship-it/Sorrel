#!/usr/bin/env python3
"""Birch's birch-leaf icon for the Chromium edition, made at build time from
the Mac app's Resources/AppIcon.icns (read only; never modified).

  python3 -I make_icons.py <AppIcon.icns> <out dir>

Writes birch.png (256 px, the window icon), birch-<size>.png for every size
in the .icns, and birch.ico (16, 32, 64, 128 and 256 px, PNG-compressed
entries, which Windows supports since Vista). Standard library only.
"""
import os
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def read_icns(path):
    data = open(path, "rb").read()
    if data[:4] != b"icns":
        sys.exit("make_icons: not an .icns file")
    entries, i = {}, 8
    while i + 8 <= len(data):
        kind = data[i:i + 4].decode("latin-1")
        length = struct.unpack(">I", data[i + 4:i + 8])[0]
        if length < 8:
            break
        entries[kind] = data[i + 8:i + length]
        i += length
    return entries


def png_size(blob):
    return struct.unpack(">II", blob[16:24])


def unpack_argb(blob, side):
    """Apple's ARGB icon data (ic04/ic05): 'ARGB' + one RLE run per channel."""
    if blob[:4] != b"ARGB":
        return None
    src, pos, out = blob[4:], 0, bytearray()
    while pos < len(src) and len(out) < side * side * 4:
        b = src[pos]
        pos += 1
        if b & 0x80:
            count = b - 125
            out += bytes([src[pos]]) * count
            pos += 1
        else:
            count = b + 1
            out += src[pos:pos + count]
            pos += count
    n = side * side
    if len(out) < 4 * n:
        return None
    a, r, g, bl = out[0:n], out[n:2 * n], out[2 * n:3 * n], out[3 * n:4 * n]
    rgba = bytearray()
    for k in range(n):
        rgba += bytes([r[k], g[k], bl[k], a[k]])
    return bytes(rgba)


def encode_png(rgba, side):
    raw = b"".join(b"\x00" + rgba[y * side * 4:(y + 1) * side * 4] for y in range(side))

    def chunk(tag, body):
        return (struct.pack(">I", len(body)) + tag + body +
                struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0)
    return PNG_SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def write_ico(path, pngs):
    """pngs: list of (size, png bytes), sizes <= 256."""
    header = struct.pack("<HHH", 0, 1, len(pngs))
    offset = 6 + 16 * len(pngs)
    entries, blobs = b"", b""
    for size, blob in pngs:
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(blob), offset)
        blobs += blob
        offset += len(blob)
    with open(path, "wb") as f:
        f.write(header + entries + blobs)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    icns, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    pngs = {}
    for kind, blob in read_icns(icns).items():
        if blob[:8] == PNG_SIG:
            w, h = png_size(blob)
            if w == h:
                pngs.setdefault(w, blob)
        elif kind == "ic04":
            rgba = unpack_argb(blob, 16)
            if rgba:
                pngs.setdefault(16, encode_png(rgba, 16))
    if 256 not in pngs:
        sys.exit("make_icons: the .icns has no 256 px image")
    for size, blob in sorted(pngs.items()):
        with open(os.path.join(out, f"birch-{size}.png"), "wb") as f:
            f.write(blob)
    with open(os.path.join(out, "birch.png"), "wb") as f:
        f.write(pngs[256])
    ico = [(s, pngs[s]) for s in (16, 32, 64, 128, 256) if s in pngs]
    write_ico(os.path.join(out, "birch.ico"), ico)
    print("make_icons: sizes " + ",".join(str(s) for s in sorted(pngs)) +
          " ico " + ",".join(str(s) for s, _ in ico))


if __name__ == "__main__":
    main()
