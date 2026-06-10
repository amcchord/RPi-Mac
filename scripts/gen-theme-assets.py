#!/usr/bin/env python3
"""Generate the Plymouth theme images (checkerboard tile + Happy Mac).

Pure-stdlib PNG writer so the assets can be regenerated anywhere. The
generated files are committed to the repo; re-running this script is
idempotent (same input -> same output).

Usage: gen-theme-assets.py [output_dir]
"""

import os
import struct
import sys
import zlib

BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


def write_png(path, width, height, pixels):
    """pixels: list of rows, each row a list of (r, g, b, a) tuples."""

    def chunk(tag, data):
        block = tag + data
        return struct.pack(">I", len(data)) + block + struct.pack(
            ">I", zlib.crc32(block) & 0xFFFFFFFF
        )

    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type none
        for r, g, b, a in row:
            raw.extend((r, g, b, a))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(png)
    print("wrote %s (%dx%d)" % (path, width, height))


def make_checker(path):
    """64x64 tile of the classic 1px grey dither (alternating B/W)."""
    size = 64
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            if (x + y) % 2 == 0:
                row.append(BLACK)
            else:
                row.append(WHITE)
        rows.append(row)
    write_png(path, size, size, rows)


def make_happy_mac(path, scale=4):
    """A 32x32 compact-Mac-with-smile pixel icon, scaled up nearest."""
    size = 32
    # start fully transparent
    grid = []
    for _ in range(size):
        grid.append([CLEAR] * size)

    def fill_rect(x0, y0, x1, y1, color):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                grid[y][x] = color

    def outline_rect(x0, y0, x1, y1, color):
        for x in range(x0, x1 + 1):
            grid[y0][x] = color
            grid[y1][x] = color
        for y in range(y0, y1 + 1):
            grid[y][x0] = color
            grid[y][x1] = color

    def put(x, y, color):
        grid[y][x] = color

    # Compact Mac body (white fill, black outline), slightly rounded corners
    fill_rect(5, 2, 26, 29, WHITE)
    outline_rect(5, 2, 26, 29, BLACK)
    for x, y in ((5, 2), (26, 2), (5, 29), (26, 29)):
        put(x, y, CLEAR)
    put(6, 3, BLACK)
    put(25, 3, BLACK)
    put(6, 28, BLACK)
    put(25, 28, BLACK)

    # Screen bezel
    outline_rect(8, 5, 23, 17, BLACK)

    # Face: eyes
    for y in range(8, 11):
        put(13, y, BLACK)
        put(18, y, BLACK)
    # nose
    put(15, 10, BLACK)
    put(16, 11, BLACK)
    # smile
    put(12, 12, BLACK)
    put(13, 13, BLACK)
    for x in range(14, 18):
        put(x, 14, BLACK)
    put(18, 13, BLACK)
    put(19, 12, BLACK)

    # Floppy slot + chin detail
    for x in range(11, 21):
        put(x, 21, BLACK)
    for x in range(8, 11):
        put(x, 24, BLACK)

    # scale up (nearest neighbour)
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            row.extend([grid[y][x]] * scale)
        for _ in range(scale):
            rows.append(list(row))
    write_png(path, size * scale, size * scale, rows)


def main():
    out_dir = "stage-mac/04-plymouth-theme/files/classicmac"
    if len(sys.argv) > 1:
        out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    make_checker(os.path.join(out_dir, "checker.png"))
    make_happy_mac(os.path.join(out_dir, "happymac.png"))


if __name__ == "__main__":
    main()
