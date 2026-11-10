#!/usr/bin/env python3
"""Draw the layout dump from tools/angelhub/layout.lua into a PNG.

Pure stdlib: zlib + struct, no Pillow in the sandbox. Filled rounded rects,
1px borders, alpha blended in source order, and text drawn as a dim underline
bar sized from the label box so alignment is visible.
"""
from __future__ import annotations

import json
import math
import struct
import sys
import zlib
from pathlib import Path

WIDTH, HEIGHT = 1280, 720
BACKGROUND = (16, 16, 19)


def parse(path: Path) -> list[dict]:
    nodes = []
    inside = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "LAYOUT_JSON_BEGIN":
            inside = True
            continue
        if line == "LAYOUT_JSON_END":
            break
        if inside and line.startswith("{"):
            nodes.append(json.loads(line))
    return nodes


class Canvas:
    def __init__(self, width: int, height: int) -> None:
        self.width = width
        self.height = height
        self.pixels = bytearray(bytes(BACKGROUND) * (width * height))

    def blend(self, x: int, y: int, color: tuple[float, float, float], alpha: float) -> None:
        if x < 0 or y < 0 or x >= self.width or y >= self.height or alpha <= 0:
            return
        index = (y * self.width + x) * 3
        for channel in range(3):
            old = self.pixels[index + channel]
            self.pixels[index + channel] = int(max(0, min(255, old + (color[channel] * 255 - old) * alpha)))

    def rect(self, x: float, y: float, w: float, h: float, color, alpha: float, radius: float = 0.0) -> None:
        if alpha <= 0 or w <= 0 or h <= 0:
            return
        x0, y0 = int(round(x)), int(round(y))
        x1, y1 = int(round(x + w)), int(round(y + h))
        r = max(0.0, min(radius, min(w, h) / 2))
        for py in range(max(0, y0), min(self.height, y1)):
            for px in range(max(0, x0), min(self.width, x1)):
                if r > 0:
                    # Distance from the nearest corner centre decides coverage.
                    cx = min(max(px + 0.5, x0 + r), x1 - r)
                    cy = min(max(py + 0.5, y0 + r), y1 - r)
                    if math.hypot(px + 0.5 - cx, py + 0.5 - cy) > r:
                        continue
                self.blend(px, py, color, alpha)

    def border(self, x, y, w, h, color, alpha, thickness=1.0, radius=0.0) -> None:
        self.rect(x, y, w, thickness, color, alpha, 0)
        self.rect(x, y + h - thickness, w, thickness, color, alpha, 0)
        self.rect(x, y, thickness, h, color, alpha, 0)
        self.rect(x + w - thickness, y, thickness, h, color, alpha, 0)

    def png(self) -> bytes:
        raw = bytearray()
        stride = self.width * 3
        for row in range(self.height):
            raw.append(0)
            raw.extend(self.pixels[row * stride : (row + 1) * stride])

        def chunk(tag: bytes, data: bytes) -> bytes:
            body = tag + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        header = struct.pack(">IIBBBBB", self.width, self.height, 8, 2, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b"")
        )


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: render.py <layout.txt> [out.png]", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    out = Path(sys.argv[2] if len(sys.argv) > 2 else "build/AngelHub.png")
    nodes = parse(source)
    if not nodes:
        print("render: no nodes parsed", file=sys.stderr)
        return 1

    canvas = Canvas(WIDTH, HEIGHT)

    # Subtle backdrop so the window edge is visible against the canvas.
    for index in range(60):
        alpha = 0.01 + index * 0.0004
        canvas.rect(0, 0, WIDTH, HEIGHT, (0.35, 0.4, 0.55), alpha, 0)

    for node in nodes:
        if not node.get("fill"):
            continue
        transparency = node.get("transparency") or 0
        alpha = max(0.0, 1.0 - transparency)
        if node.get("w", 0) <= 0 or node.get("h", 0) <= 0:
            continue
        fill = node.get("fill") or [1, 1, 1]
        # A gradient's own Transparency sequence modulates the fill; without
        # this the sheen and title-bar overlays paint as solid white.
        gradient_alpha = node.get("gradient_alpha", 1.0) or 0.0
        alpha *= gradient_alpha
        canvas.rect(node["x"], node["y"], node["w"], node["h"], fill, alpha, node.get("radius") or 0)
        stroke = node.get("stroke")
        if stroke:
            canvas.border(
                node["x"], node["y"], node["w"], node["h"],
                stroke["color"], max(0.0, 1.0 - stroke["transparency"]), stroke["thickness"],
            )

    for node in nodes:
        if not node.get("text"):
            continue
        color = node.get("color") or [1, 1, 1]
        size = node.get("size", 12)
        # Placeholder bar: proportional to the reported label box, one line tall.
        bar_height = max(2, int(size * 0.5))
        y = node["y"] + (node["h"] - bar_height) / 2
        text = node.get("text", "")
        bar_width = min(node["w"], max(6, len(text) * size * 0.55))
        x = node["x"]
        if "Center" in str(node.get("align")):
            x = node["x"] + (node["w"] - bar_width) / 2
        elif "Right" in str(node.get("align")):
            x = node["x"] + node["w"] - bar_width
        canvas.rect(x, y, bar_width, bar_height, color, 0.92, bar_height / 2)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(canvas.png())
    print(f"render: {len(nodes)} nodes -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
