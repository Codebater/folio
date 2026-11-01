"""Draws Folio's placeholder app icon (1024x1024 PNG) with the standard library.

    python -I scripts/make_app_icon.py Apps/FolioiOS/Folio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

An open page on warm paper with text lines and one highlighted word: the
read-along idea in one picture. Replace with a designed icon before release.
"""
import struct
import sys
import zlib

W = H = 1024
BG_TOP, BG_BOTTOM = (0x2E, 0x26, 0x21), (0x4A, 0x3A, 0x2E)
PAGE, LINE, MARK = (0xF6, 0xEF, 0xE3), (0x8C, 0x7A, 0x6A), (0xE0, 0xA4, 0x58)


def rounded_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def pixel(x, y):
    t = y / H
    color = tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3))
    if rounded_rect(x, y, 232, 170, 792, 854, 40):
        color = PAGE
        # text lines; the fourth line carries a highlighted word
        for i, (start, end) in enumerate([(300, 724), (300, 690), (300, 724), (300, 640), (300, 710), (300, 600)]):
            top = 290 + i * 86
            if rounded_rect(x, y, start, top, end, top + 26, 13):
                color = LINE
            if i == 3 and rounded_rect(x, y, 430, top - 14, 596, top + 40, 14):
                color = MARK if not rounded_rect(x, y, 446, top, 580, top + 26, 13) else LINE
    return color


def main(path):
    rows = []
    for y in range(H):
        row = bytearray([0])
        for x in range(W):
            row.extend(pixel(x, y))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print(f"wrote {path} ({len(png)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1])
