#!/usr/bin/env python3
"""Draw the layout dump from tools/fatchub/layout.lua into a PNG.

Two things this renderer does that the first one did not:

  * **Real text.** tools/fatchub/font.py rasterises the actual face, so the
    screenshot is readable and a cut word is visibly cut. Text is truncated
    the way Roblox's TextTruncate.AtEnd does it, and TextWrapped labels break
    on words inside their box.
  * **Speed.** Fills and strokes are coverage-computed per scanline instead of
    per pixel (see _fill / _ring), so a whole menu renders in about a second
    rather than the minute the per-pixel loop took.

Output is a plain RGB PNG built with zlib + struct. No Pillow, same as before.

    python3 tools/fatchub/render.py build/layout.txt build/FatCatHub.png
    python3 tools/fatchub/render.py build/layout.txt --zoom 2 --out big.png
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import font as fontmod  # noqa: E402

WIDTH, HEIGHT = 1280, 720
BACKDROP = (0.13, 0.15, 0.2)


# --------------------------------------------------------------------------
# Canvas
# --------------------------------------------------------------------------


class Canvas:
    """RGB float canvas with analytic rounded-rect fills and rings."""

    def __init__(self, width: int, height: int, zoom: int = 1) -> None:
        self.width = width
        self.height = height
        self.zoom = zoom
        # One float per channel: blending in floats keeps repeated overlays
        # from banding, and only the final PNG quantises.
        self.pixels = [0.0] * (width * height * 3)
        self.pixels[0::3] = [BACKDROP[0]] * (width * height)
        self.pixels[1::3] = [BACKDROP[1]] * (width * height)
        self.pixels[2::3] = [BACKDROP[2]] * (width * height)

    # -- internal ---------------------------------------------------------
    def _clip(self, x, y, w, h, clips):
        """Intersect a rect with the *union* of its clip ancestors' insets.

        The dump lists every clipping ancestor's rect. A rect is visible when
        it is inside at least one of them, not inside all at once, so the
        effective bounds are the outermost rectangle (min left, max right).
        """
        if clips:
            x0 = min(clip[0] for clip in clips)
            y0 = min(clip[1] for clip in clips)
            x1 = max(clip[0] + clip[2] for clip in clips)
            y1 = max(clip[1] + clip[3] for clip in clips)
            clips = [(x0, y0, x1 - x0, y1 - y0)]
        for clip in clips or []:
            cx, cy, cw, ch = clip
            left = max(x, cx)
            top = max(y, cy)
            right = min(x + w, cx + cw)
            bottom = min(y + h, cy + ch)
            x, y, w, h = left, top, right - left, bottom - top
            if w <= 0 or h <= 0:
                return None
        return (x, y, w, h)

    def _blend_row(self, row: int, start: int, end: int, color, alpha: float) -> None:
        if alpha <= 0 or start >= end:
            return
        start = max(0, start)
        end = min(self.width, end)
        if start >= end:
            return
        base = (row * self.width + start) * 3
        count = end - start
        if alpha >= 1.0:
            # Exact stop: base + count*3, or the slice drags in neighbours.
            stop = base + count * 3
            self.pixels[base:stop:3] = [color[0]] * count
            self.pixels[base + 1 : stop : 3] = [color[1]] * count
            self.pixels[base + 2 : stop : 3] = [color[2]] * count
            return
        inv = 1.0 - alpha
        px = self.pixels
        for channel in range(3):
            value = color[channel]
            offset = base + channel
            for index in range(offset, offset + count * 3, 3):
                px[index] = px[index] * inv + value * alpha

    @staticmethod
    def _span(px: float, local_y: float, w: float, h: float, radius: float) -> float:
        """Horizontal coverage of a rounded rect's silhouette on one row.

        `local_y` is relative to the rect's top edge, not a screen row.
        """
        if radius <= 0:
            return w
        centre = min(max(local_y, radius), h - radius)
        dy = abs(local_y - centre)
        if dy >= radius:
            return 0.0
        inset = radius - math.sqrt(max(0.0, radius * radius - dy * dy))
        return max(0.0, w - 2 * inset)

    def _fill(self, x, y, w, h, radius, color, alpha, clips) -> None:
        box = self._clip(x, y, w, h, clips)
        if box is None:
            return
        x, y, w, h = box
        radius = max(0.0, min(radius, min(w, h) / 2))
        x0, y0 = int(math.floor(x)), int(math.floor(y))
        x1, y1 = int(math.ceil(x + w)), int(math.ceil(y + h))
        for py in range(max(0, y0), min(self.height, y1)):
            span = self._span(x, py - y, w, h, radius)
            if span <= 0:
                continue
            self._blend_row(py, int(round(x)), int(round(x + span)), color, alpha)

    def _ring(self, x, y, w, h, radius, thickness, color, alpha, clips) -> None:
        """A border: the silhouette minus the silhouette inset by thickness."""
        box = self._clip(x, y, w, h, clips)
        if box is None:
            return
        x, y, w, h = box
        radius = max(0.0, min(radius, min(w, h) / 2))
        inner_r = max(0.0, radius - thickness)
        y0, y1 = int(math.floor(y)), int(math.ceil(y + h))
        for py in range(max(0, y0), min(self.height, y1)):
            outer = self._span(x, py - y, w, h, radius)
            inner = self._span(
                x + thickness, py - thickness - y, w - 2 * thickness, h - 2 * thickness, inner_r
            )
            if outer <= 0:
                continue
            ox = int(round(x))
            if inner <= 0:
                self._blend_row(py, ox, int(round(x + outer)), color, alpha)
                continue
            ix = int(round(x + thickness))
            ix1 = int(round(x + thickness + inner))
            self._blend_row(py, ox, ix, color, alpha)
            self._blend_row(py, ix1, int(round(x + outer)), color, alpha)

    def _mask(self, dx: int, dy: int, mask, color, alpha, clip_x0: int, clip_x1: int,
              clip_y0: int, clip_y1: int) -> None:
        """Blend one glyph mask, clipped to its label box."""
        mw, mh, _, _, data = mask
        for row in range(mh):
            py = dy + row
            if py < clip_y0 or py >= clip_y1 or py < 0 or py >= self.height:
                continue
            base = row * mw
            span_start = None
            for col in range(mw + 1):
                covered = col < mw and data[base + col] > 0
                if covered and span_start is None:
                    span_start = col
                elif not covered and span_start is not None:
                    start = max(clip_x0, dx + span_start)
                    end = min(clip_x1, dx + col)
                    if end > start:
                        self._blend_row(py, start, end, color, alpha)
                    span_start = None

    # -- public -----------------------------------------------------------
    def fill(self, x, y, w, h, color, alpha, radius=0.0, clips=None) -> None:
        self._fill(x, y, w, h, radius, color, alpha, clips)

    def border(self, x, y, w, h, color, alpha, thickness=1.0, radius=0.0, clips=None) -> None:
        self._ring(x, y, w, h, radius, thickness, color, alpha, clips)

    def line(self, x0, y0, x1, y1, color, alpha=1.0) -> None:
        """Thin horizontal/vertical/45° helper for the artefact chrome."""
        if abs(y1 - y0) <= abs(x1 - x0):
            self.fill(min(x0, x1), y0, abs(x1 - x0), 1, color, alpha, 0)
        else:
            self.fill(x0, min(y0, y1), 1, abs(y1 - y0), color, alpha, 0)

    def text(self, text: str, x, y, size, color, alpha, font_family="Gotham", align="Left",
             box_w=None, box_h=None, valign="Center", wrap=False, line_gap=1.0) -> dict:
        """Draw text the way the Roblox label would, and report what happened.

        Returns {"drawn": str, "truncated": bool, "lines": [...], "width": px}.
        """
        face = fontmod.load(font_family) or fontmod.load("Gotham")
        if face is None or not text:
            return {"drawn": "", "truncated": False, "lines": [], "width": 0.0}
        if box_w is None:
            box_w = face.text_width(text, size) + 1
        lines = []
        truncated = False
        if wrap and box_w > 0:
            lines = _wrap(face, text, size, box_w)
        else:
            drawn, cut = face.truncate(text, size, box_w)
            lines = [drawn]
            truncated = cut
        lh = face.line_height(size) * line_gap
        total = lh * len(lines)
        if valign == "Top":
            top = y
        elif valign == "Bottom":
            top = y + (box_h or total) - total
        else:
            top = y + ((box_h or total) - total) / 2

        width = max(face.text_width(line, size) for line in lines)
        for index, line in enumerate(lines):
            pen = x
            if align == "Center":
                pen = x + (box_w - face.text_width(line, size)) / 2
            elif align == "Right":
                pen = x + box_w - face.text_width(line, size)
            baseline = top + index * lh + face.ascent * size
            self._draw_line(
                face, line, pen, baseline, size, color, alpha,
                int(math.floor(x)), int(math.ceil(x + box_w)),
                int(math.floor(y)), int(math.ceil(y + (box_h if box_h is not None else total))),
            )
        return {"drawn": "\n".join(lines), "truncated": truncated, "lines": lines, "width": width}

    def _draw_line(self, face, line, pen, baseline, size, color, alpha,
                   box_x0: int, box_x1: int, box_y0: int, box_y1: int) -> None:
        cursor = pen
        for char in line:
            if char == " ":
                cursor += face.advance(char) / face.upem * size
                continue
            mask = face.glyph_mask(char, size)
            mw, mh, ox, oy, data = mask
            if mw and mh:
                dx = int(round(cursor + ox))
                dy = int(round(baseline + oy))
                self._mask(dx, dy, mask, color, alpha, box_x0, box_x1, box_y0, box_y1)
            cursor += face.advance(char) / face.upem * size

    # -- output -----------------------------------------------------------
    def png(self) -> bytes:
        raw = bytearray()
        stride = self.width * 3
        px = self.pixels
        for row in range(self.height):
            raw.append(0)
            start = row * stride
            for index in range(start, start + stride):
                raw.append(max(0, min(255, int(px[index] * 255 + 0.5))))

        def chunk(tag: bytes, data: bytes) -> bytes:
            body = tag + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        def chunk_raw(tag: bytes, data: bytes) -> bytes:
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        header = struct.pack(">IIBBBBB", self.width, self.height, 8, 2, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk_raw(b"IHDR", header)
            + chunk_raw(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk_raw(b"IEND", b"")
        )


def _wrap(face, text: str, size: float, width: float) -> list[str]:
    lines, current = [], ""
    for word in text.split(" "):
        candidate = word if not current else current + " " + word
        if face.text_width(candidate, size) <= width or not current:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


# --------------------------------------------------------------------------
# Parsing and painting
# --------------------------------------------------------------------------


def parse(path: Path) -> tuple[list[dict], int]:
    nodes = []
    inside = False
    count = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "LAYOUT_JSON_BEGIN":
            inside = True
            continue
        if line == "LAYOUT_JSON_END":
            inside = False
            continue
        if line.startswith("LAYOUT_NODES "):
            count = int(line.split()[1])
        elif inside and line.startswith("{"):
            nodes.append(json.loads(line))
    return nodes, count



def draw_surfaces(canvas: "Canvas", nodes: list[dict]) -> None:
    """Paint every background, gradient and border, in the order given.

    Shared with tools/fatchub/audit.py, which needs the surface pass on its own
    to sample what colour a label is actually sitting on.
    """
    for node in nodes:
        clips = clip_rects(node)
        opacity = max(0.0, 1.0 - (node.get("transparency") or 0))
        group = node.get("group_alpha", 1.0) or 1.0
        gradient = node.get("gradient_alpha", 1.0)
        alpha = opacity * group * (gradient if gradient is not None else 1.0)
        if alpha > 0.004 and node.get("w", 0) > 0 and node.get("h", 0) > 0:
            canvas.fill(
                node["x"], node["y"], node["w"], node["h"],
                node.get("fill") or [1, 1, 1], alpha, node.get("radius") or 0, clips,
            )
        stroke = node.get("stroke")
        if stroke:
            stroke_alpha = max(0.0, 1.0 - stroke.get("transparency", 0)) * group
            if stroke_alpha > 0.004:
                canvas.border(
                    node["x"], node["y"], node["w"], node["h"],
                    stroke["color"], stroke_alpha, stroke.get("thickness", 1),
                    node.get("radius") or 0, clips,
                )


def clip_rects(node: dict) -> list[tuple[float, float, float, float]]:
    return [(c["x"], c["y"], c["w"], c["h"]) for c in node.get("clip") or []]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("layout", type=Path)
    parser.add_argument("out", nargs="?", type=Path, help="output PNG (same as --out)")
    parser.add_argument("--out", dest="out_flag", type=Path, default=None)
    parser.add_argument("--zoom", type=int, default=1)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if not args.layout.exists():
        print(f"render: {args.layout} not found", file=sys.stderr)
        return 2
    nodes, declared = parse(args.layout)
    if not nodes:
        print("render: no nodes parsed", file=sys.stderr)
        return 1

    out_path = args.out_flag or args.out or Path("build/FatCatHub.png")
    zoom = max(1, min(4, args.zoom))
    canvas = Canvas(WIDTH * zoom, HEIGHT * zoom, zoom)
    # Zoom by drawing in the same coordinate system: canvas is scaled, so all
    # geometry is multiplied once here.
    if zoom != 1:
        for node in nodes:
            for key in ("x", "y", "w", "h", "radius", "size"):
                if key in node:
                    node[key] *= zoom
            if node.get("clip"):
                node["clip"] = [
                    {**c, **{k: c[k] * zoom for k in ("x", "y", "w", "h")}} for c in node["clip"]
                ]
            if node.get("stroke"):
                node["stroke"]["thickness"] *= zoom

    # Backdrop: a soft vertical wash, then a grid so alignment reads at a glance.
    for row in range(0, canvas.height, 2):
        t = row / max(1, canvas.height)
        shade = 0.045 + 0.02 * t
        canvas.fill(0, row, canvas.width, 1, (0.32, 0.38, 0.55), shade, 0)
    grid = (0.55, 0.6, 0.75)
    for x in range(0, canvas.width, 40 * zoom):
        canvas.fill(x, 0, 1, canvas.height, grid, 0.035, 0)
    for y in range(0, canvas.height, 40 * zoom):
        canvas.fill(0, y, canvas.width, 1, grid, 0.035, 0)

    # Roblox paints by accumulated ZIndex, not by tree order; the window's
    # shadow sits at z=-1 behind the frame even though it is emitted after it.
    paint_order = sorted(nodes, key=lambda node: node.get("z", 1))
    draw_surfaces(canvas, paint_order)

    # Pass 2: glyphs.
    text_report = []
    for node in paint_order:
        if not node.get("text"):
            continue
        clips = clip_rects(node)
        box = canvas._clip(node["x"], node["y"], node["w"], node["h"], clips)
        if box is None:
            continue
        alpha = (node.get("text_opacity", node.get("opacity", 1.0)) or 1.0) * (node.get("group_alpha", 1.0) or 1.0)
        if alpha <= 0.02:
            continue
        # A TextBox placeholder is dimmer than typed text; the menu relies on it.
        color = node.get("color") or [1, 1, 1]
        result = canvas.text(
            node["text"], box[0], box[1], node.get("size", 12), color, alpha,
            font_family=node.get("font", "Gotham"), align=node.get("align", "Left"),
            box_w=box[2], box_h=box[3], valign=node.get("valign", "Center"),
            wrap=bool(node.get("wrap")),
        )
        text_report.append((node, result, box))

    # Painter's algorithm already applied above, but a clipped surface that
    # fully hid a label still gets counted; report the damage, and mark it in
    # the image with a hairline under the box so it is visible in review.
    # Same rules as the audit: half a pixel is float noise from scale/offset
    # resolution, and a scrolling ancestor clips by design (drag to the rest).
    clipped_text = []
    for node, result, box in text_report:
        # Content inside a ScrollingFrame is reachable by dragging, so it is
        # not "clipped" in the design sense - same rule the audit applies.
        if node.get("scrolls"):
            continue
        for clip in node.get("clip") or []:
            if clip.get("scroll"):
                continue
            right = clip["x"] + clip["w"]
            bottom = clip["y"] + clip["h"]
            if (node["x"] + node["w"] > right + 0.5
                    or node["y"] + node["h"] > bottom + 0.5):
                clipped_text.append(node.get("name") or node.get("text", "")[:30])
                break

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(canvas.png())
    if not args.quiet:
        state = "ok" if declared == len(nodes) else f"MISMATCH (declared {declared})"
        print(f"render: {len(nodes)} nodes, {len(text_report)} labels -> {out_path}  [{state}]")
        info = fontmod.describe()
        gotham = info["Gotham"]["path"]
        print(f"render: face {Path(gotham).name if gotham else 'none'} | zoom {zoom}x | "
              f"{len(clipped_text)} clipped label box(es)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
