#!/usr/bin/env python3
"""A tiny TrueType reader: metrics, kerning-free advance, and glyph masks.

Pure stdlib (struct only). It exists because the design harness has to answer
two questions the old renderer could not:

  1. "how wide is this label at this TextSize?"  -> text_width()
  2. "draw it so a human can read the screenshot" -> glyph_mask()

Both are approximations of Roblox's Gotham: the menu's fonts are mapped in
FONT_FILES below to the closest freely available face. Text measured here is
therefore a hair wider than Gotham (DejaVu is generous), which is what a fit
audit wants - if it fits in DejaVu it fits in Gotham.

Supported: format 4 cmap (the BMP), simple and composite glyf outlines, and
coverage rasterisation by 4x4 supersampling. No hinting, no kerning, no GPOS.
"""

from __future__ import annotations

import math
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Where the faces live
# --------------------------------------------------------------------------
# Roblox font -> (serif?, bold?, mono?). The design harness resolves the real
# file through candidate_faces() so a clone on macOS or a distro without
# DejaVu still finds *a* face instead of failing.
FONT_STACKS = {
    "Gotham": ["DejaVuSans.ttf", "LiberationSans-Regular.ttf", "Arial.ttf", "Helvetica.ttc"],
    "GothamBold": ["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "Arial Bold.ttf"],
    "GothamMedium": ["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "Arial Bold.ttf"],
    "SourceSans": ["DejaVuSans.ttf", "LiberationSans-Regular.ttf"],
    "SourceSansBold": ["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf"],
    "RobotoMono": ["DejaVuSansMono.ttf", "LiberationMono-Regular.ttf", "Courier New.ttf"],
    "Code": ["DejaVuSansMono.ttf", "LiberationMono-Regular.ttf"],
}

FONT_DIRS = [
    Path("/usr/share/fonts/truetype"),
    Path("/usr/share/fonts"),
    Path("/usr/local/share/fonts"),
    Path.home() / "Library/Fonts",
    Path("/Library/Fonts"),
    Path("/System/Library/Fonts"),
]


def candidate_faces():
    """Every (name, path) found on this machine, best first per family."""
    found = {}
    for directory in FONT_DIRS:
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            if path.suffix.lower() in (".ttf", ".otf"):
                found.setdefault(path.name, path)
    return found


def resolve_font(family: str):
    """Pick a real file for a Roblox font name, or None when nothing matches."""
    available = candidate_faces()
    for name in FONT_STACKS.get(family, []):
        if name in available:
            return available[name]
    # Last resort: any regular sans face.
    for name in ("DejaVuSans.ttf", "LiberationSans-Regular.ttf"):
        if name in available:
            return available[name]
    return None


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------


@dataclass
class GlyphOutline:
    """Contours of quadratic segments in font units, y up."""

    contours: list[list[tuple[float, float, int]]] = field(default_factory=list)
    # Each point is (x, y, on_curve) with on_curve in {0, 1}.

    @property
    def bbox(self):
        xs = [p[0] for c in self.contours for p in c]
        ys = [p[1] for c in self.contours for p in c]
        if not xs:
            return (0.0, 0.0, 0.0, 0.0)
        return (min(xs), min(ys), max(xs), max(ys))


class TrueTypeFont:
    """Just enough TrueType to measure and rasterise."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.tables = self._read_directory()
        self.upem = self._read_head()
        self.ascent, self.descent = self._read_hhea()
        self._cmap = self._read_cmap()
        self._advances = self._read_hmtx()
        self._masks: dict[tuple[int, int], tuple[int, int, int, int, bytearray]] = {}

    # -- directory ---------------------------------------------------------
    def _read_directory(self):
        data = self.data
        num = struct.unpack(">H", data[4:6])[0]
        tables = {}
        for index in range(num):
            offset = 12 + index * 16
            tag = data[offset : offset + 4].decode("latin-1")
            _, table_offset, length = struct.unpack(">III", data[offset + 4 : offset + 16])
            tables[tag] = (table_offset, length)
        return tables

    def _u16(self, offset: int) -> int:
        return struct.unpack(">H", self.data[offset : offset + 2])[0]

    def _i16(self, offset: int) -> int:
        return struct.unpack(">h", self.data[offset : offset + 2])[0]

    def _u32(self, offset: int) -> int:
        return struct.unpack(">I", self.data[offset : offset + 4])[0]

    def _read_head(self):
        offset = self.tables["head"][0]
        return self._u16(offset + 18) or 1000  # unitsPerEm

    def _read_hhea(self):
        offset = self.tables["hhea"][0]
        ascent = self._i16(offset + 4) / self.upem
        descent = self._i16(offset + 6) / self.upem
        return ascent, descent

    # -- cmap --------------------------------------------------------------
    def _read_cmap(self):
        base = self.tables["cmap"][0]
        count = self._u16(base + 2)
        subtable = None
        for index in range(count):
            platform, encoding, offset = struct.unpack(
                ">HHI", self.data[base + 4 + index * 8 : base + 12 + index * 8]
            )
            if (platform, encoding) in ((3, 1), (3, 0), (0, 3), (0, 4), (0, 6)):
                subtable = base + offset
        if subtable is None:
            return {}
        fmt = self._u16(subtable)
        if fmt == 4:
            return self._cmap_format4(subtable)
        if fmt == 12:
            return self._cmap_format12(subtable)
        return {}

    def _cmap_format4(self, offset):
        seg_x2 = self._u16(offset + 6)
        segments = seg_x2 // 2
        ends_at = offset + 14
        starts_at = ends_at + seg_x2 + 2
        deltas_at = starts_at + seg_x2
        ranges_at = deltas_at + seg_x2
        mapping = {}
        for index in range(segments):
            end = self._u16(ends_at + index * 2)
            start = self._u16(starts_at + index * 2)
            delta = self._i16(deltas_at + index * 2)
            range_offset = self._u16(ranges_at + index * 2)
            if start == 0xFFFF:
                continue
            for code in range(start, min(end, 0xFFFE) + 1):
                if range_offset == 0:
                    glyph = (code + delta) & 0xFFFF
                else:
                    glyph_at = ranges_at + index * 2 + range_offset + (code - start) * 2
                    glyph = self._u16(glyph_at)
                    if glyph:
                        glyph = (glyph + delta) & 0xFFFF
                if glyph:
                    mapping[code] = glyph
        return mapping

    def _cmap_format12(self, offset):
        groups = self._u32(offset + 12)
        mapping = {}
        for index in range(groups):
            start, end, glyph = struct.unpack(
                ">III", self.data[offset + 16 + index * 12 : offset + 28 + index * 12]
            )
            for code in range(start, min(end, start + 4096) + 1):
                mapping[code] = glyph + (code - start)
        return mapping

    def _read_hmtx(self):
        offset = self.tables["hmtx"][0]
        count = self._u16(self.tables["hhea"][0] + 34)
        advances = []
        for index in range(count):
            advances.append(self._u16(offset + index * 4))
        return advances

    # -- outlines ----------------------------------------------------------
    def _loca(self):
        offset, _ = self.tables["loca"]
        long_entries = self._i16(self.tables["head"][0] + 50) == 1
        count = self._u16(self.tables["maxp"][0] + 4) if "maxp" in self.tables else len(self._advances) + 1
        entries = []
        for index in range(count + 1):
            if long_entries:
                entries.append(self._u32(offset + index * 4))
            else:
                entries.append(self._u16(offset + index * 2) * 2)
        return entries

    def glyph_id(self, char: str) -> int:
        return self._cmap.get(ord(char), 0)

    def glyph_outline(self, glyph: int, depth: int = 0) -> GlyphOutline:
        """Outline for a glyph id, composites resolved into place."""
        if glyph == 0 or depth > 4:
            return GlyphOutline()
        loca = self._loca()
        if glyph + 1 >= len(loca):
            return GlyphOutline()
        glyf_at, _ = self.tables["glyf"]
        start, end = loca[glyph], loca[glyph + 1]
        if end <= start:
            return GlyphOutline()
        data = self.data
        base = glyf_at + start
        contours_n = struct.unpack(">h", data[base : base + 2])[0]

        if contours_n >= 0:
            return self._simple_outline(base, contours_n)

        # Composite: walk the component records.
        outline = GlyphOutline()
        cursor = base + 10
        while True:
            flags = self._u16(cursor)
            component = self._u16(cursor + 2)
            cursor += 4
            if flags & 0x0001:  # ARG_1_AND_2_ARE_WORDS
                arg1 = self._i16(cursor)
                arg2 = self._i16(cursor + 2)
                cursor += 4
            else:
                arg1 = struct.unpack(">b", data[cursor : cursor + 1])[0]
                arg2 = struct.unpack(">b", data[cursor + 1 : cursor + 2])[0]
                cursor += 2
            dx = dy = 0.0
            if flags & 0x0002:  # ARGS_ARE_XY_VALUES
                dx, dy = float(arg1), float(arg2)
            xx = yy = 1.0
            xy = yx = 0.0
            if flags & 0x0008:  # WE_HAVE_A_SCALE
                xx = yy = self._i16(cursor) / 16384.0
                cursor += 2
            elif flags & 0x0040:  # X_AND_Y_SCALE
                xx = self._i16(cursor) / 16384.0
                yy = self._i16(cursor + 2) / 16384.0
                cursor += 4
            elif flags & 0x0080:  # TWO_BY_TWO
                xx = self._i16(cursor) / 16384.0
                xy = self._i16(cursor + 2) / 16384.0
                yx = self._i16(cursor + 4) / 16384.0
                yy = self._i16(cursor + 6) / 16384.0
                cursor += 8
            child = self.glyph_outline(component, depth + 1)
            for contour in child.contours:
                moved = []
                for x, y, on in contour:
                    moved.append((x * xx + y * xy + dx, x * yx + y * yy + dy, on))
                outline.contours.append(moved)
            if not flags & 0x0020:  # MORE_COMPONENTS
                break
        return outline

    def _simple_outline(self, base, contours_n):
        data = self.data
        cursor = base + 10
        end_points = []
        for index in range(contours_n):
            end_points.append(self._u16(cursor))
            cursor += 2
        total = (end_points[-1] + 1) if end_points else 0
        # Skip the glyph's TrueType hinting program. This offset is what keeps
        # the flag array aligned; a flat `2 + length` read lands mid-flag-run
        # on glyphs with instructions and turns a letter into a blob.
        instruction_length = self._u16(cursor)
        cursor += 2 + instruction_length

        flags = []
        while len(flags) < total:
            flag = data[cursor]
            cursor += 1
            flags.append(flag)
            if flag & 0x08:  # REPEAT
                repeat = data[cursor]
                cursor += 1
                flags.extend([flag] * repeat)

        xs = []
        value = 0
        for flag in flags:
            if flag & 0x02:  # X_SHORT
                delta = data[cursor]
                cursor += 1
                value += delta if flag & 0x10 else -delta
            elif not flag & 0x10:  # same as previous
                value += self._i16(cursor)
                cursor += 2
            xs.append(value)

        ys = []
        value = 0
        for flag in flags:
            if flag & 0x04:  # Y_SHORT
                delta = data[cursor]
                cursor += 1
                value += delta if flag & 0x20 else -delta
            elif not flag & 0x20:
                value += self._i16(cursor)
                cursor += 2
            ys.append(value)

        outline = GlyphOutline()
        start = 0
        for end in end_points:
            contour = []
            for index in range(start, end + 1):
                contour.append((xs[index], ys[index], flags[index] & 0x01))
            if contour:
                outline.contours.append(contour)
            start = end + 1
        return outline

    # -- metrics -----------------------------------------------------------
    def advance(self, char: str) -> int:
        """Horizontal advance in font units."""
        glyph = self.glyph_id(char)
        if glyph < len(self._advances):
            return self._advances[glyph]
        return self.upem // 2

    def text_width(self, text: str, size: float) -> float:
        """Width of `text` in pixels at `size`, no kerning."""
        if not text:
            return 0.0
        units = sum(self.advance(char) for char in text)
        return units / self.upem * size

    def line_height(self, size: float) -> float:
        return (self.ascent - self.descent) * size

    def truncate(self, text: str, size: float, width: float, ellipsis: str = "…") -> tuple[str, bool]:
        """Roblox's TextTruncate.AtEnd, roughly: cut and add an ellipsis."""
        if self.text_width(text, size) <= width:
            return text, False
        ellipsis_width = self.text_width(ellipsis, size)
        if width <= ellipsis_width:
            return "", True
        limit = width - ellipsis_width
        kept = ""
        for char in text:
            if self.text_width(kept + char, size) > limit:
                break
            kept += char
        return kept.rstrip() + ellipsis, True

    # -- raster ------------------------------------------------------------
    def glyph_mask(self, char: str, size: float):
        """Anti-aliased coverage for one character.

        Returns (width, height, x_offset, y_offset, alpha) where alpha is a
        bytearray of width*height coverage values (0..255) and the offsets are
        in pixels from the pen position, y down (so y_offset is usually
        negative for the ascent).
        """
        key = (ord(char), round(size * 4))
        cached = self._masks.get(key)
        if cached is not None:
            return cached

        outline = self.glyph_outline(self.glyph_id(char))
        scale = size / self.upem
        x_min, y_min, x_max, y_max = outline.bbox
        if not outline.contours:
            result = (0, 0, 0, 0, bytearray())
            self._masks[key] = result
            return result

        # Pixel box, padded by one pixel so the AA fringe is not clipped.
        # Rounded outwards, and never narrower than the advance is wide: a
        # negative left bearing must not eat the glyph's own pixels.
        left = int(math.floor(x_min * scale)) - 1
        right = int(math.ceil(x_max * scale)) + 1
        top = int(math.floor(-y_max * scale)) - 1
        bottom = int(math.ceil(-y_min * scale)) + 1
        width = max(1, right - left)
        height = max(1, bottom - top)

        # Flatten quadratic contours to line segments once, in absolute pixel
        # space; the rasterizer subtracts (left, top) itself.
        polygons = []
        for contour in outline.contours:
            polygons.append(_flatten(contour, scale))

        alpha = _rasterize(polygons, width, height, samples=4, origin_x=left, origin_y=top)
        result = (width, height, left, top, alpha)
        self._masks[key] = result
        return result


def _flatten(contour, scale, steps=4):
    """Quadratic contour -> closed polygon in absolute pixel space, y down.

    TrueType mixes on-curve and off-curve points and lets two off-curve points
    sit next to each other (the on-curve point between them is implied at the
    midpoint). This normalises the contour to *only* on-curve points first, so
    the segment walk below is a plain on->off->on quadratic and cannot loop.
    """
    if len(contour) < 3:
        return []
    units = [(x * scale, -(y * scale), bool(on)) for x, y, on in contour]

    # 1. Start on an on-curve point.
    if not any(on for _, _, on in units):
        # A contour of only off-curve points is degenerate; treat them as on.
        units = [(x, y, True) for x, y, _ in units]
    while not units[0][2]:
        units = units[1:] + units[:1]

    # 2. Insert implied midpoints so no two controls are adjacent.
    normalised = []
    count = len(units)
    for index in range(count):
        x, y, on = units[index]
        normalised.append((x, y, on))
        nx, ny, n_on = units[(index + 1) % count]
        if not on and not n_on:
            normalised.append(((x + nx) / 2, (y + ny) / 2, True))

    # 3. Walk on -> (control?) -> on.
    polygon = []
    index = 0
    total = len(normalised)
    while index < total:
        x0, y0, _ = normalised[index]
        polygon.append((x0, y0))
        nxt = (index + 1) % total
        x1, y1, on1 = normalised[nxt]
        if on1:
            index += 1
            continue
        x2, y2, _ = normalised[(index + 2) % total]
        for step in range(1, steps + 1):
            t = step / steps
            inv = 1 - t
            polygon.append((
                inv * inv * x0 + 2 * inv * t * x1 + t * t * x2,
                inv * inv * y0 + 2 * inv * t * y1 + t * t * y2,
            ))
        index += 2
    return polygon


def _rasterize(polygons, width, height, samples=4, origin_x=0.0, origin_y=0.0):
    """Coverage by scanline supersampling with exact horizontal spans.

    For every sub-scanline the edge crossings are sorted and walked with the
    non-zero rule; each covered span is added to the pixel row by its
    fractional overlap. `polygons` are in font-space pixels shifted by
    (origin_x, origin_y) on the caller's side, so a glyph whose left bearing
    is negative can still be rasterised on demand *at its box position*: the
    coverage array is that glyph's box, and nothing is dropped off the left.

    O(rows * samples * edges + rows * width), which is what keeps a whole
    screenshot in the low seconds rather than the minute the per-pixel loop
    took.
    """
    coverage = [0.0] * (width * height)
    edges = []
    for polygon in polygons:
        count = len(polygon)
        for index in range(count):
            x0, y0 = polygon[index]
            x1, y1 = polygon[(index + 1) % count]
            # Absolute pixel space -> the glyph's own box: one subtraction here
            # keeps negative left bearings inside the coverage array.
            if y0 != y1:
                edges.append((x0 - origin_x, y0 - origin_y, x1 - origin_x, y1 - origin_y))
    if not edges:
        return bytearray(width * height)

    weight = 1.0 / samples
    for py in range(height):
        row = py * width
        for sy in range(samples):
            y = py + (sy + 0.5) / samples
            crossings = []
            for x0, y0, x1, y1 in edges:
                if (y0 <= y < y1) or (y1 <= y < y0):
                    t = (y - y0) / (y1 - y0)
                    crossings.append((x0 + (x1 - x0) * t, 1 if y1 > y0 else -1))
            if len(crossings) < 2:
                continue
            crossings.sort()
            winding = 0
            span_start = 0.0
            for x, direction in crossings:
                was_inside = winding != 0
                winding += direction
                inside = winding != 0
                if not was_inside and inside:
                    span_start = x
                elif was_inside and not inside:
                    _add_span(coverage, row, span_start, x, width, weight)
    alpha = bytearray(width * height)
    for index, value in enumerate(coverage):
        if value > 0:
            alpha[index] = 255 if value >= 1 else int(value * 255)
    return alpha


def _add_span(coverage, row, start, end, width, weight):
    """Add one covered horizontal span, with partial pixels at both ends."""
    if end < start:
        start, end = end, start
    if end <= 0 or start >= width:
        return
    start = max(0.0, start)
    end = min(float(width), end)
    first = int(start)
    # `end` may sit exactly on the right border (the flat side of a stem), so
    # the last touched pixel is ceil(end)-1, never `end` itself.
    last = int(end) if end > int(end) else int(end) - 1
    if last < first:
        return
    coverage[row + first] += (min(end, first + 1.0) - start) * weight
    for pixel in range(first + 1, last):
        coverage[row + pixel] += weight
    if last > first or end > first + 1.0:
        coverage[row + last] += (end - max(start, float(last))) * weight


# --------------------------------------------------------------------------
# Cache of loaded faces, keyed by family name
# --------------------------------------------------------------------------
_CACHE: dict[str, TrueTypeFont | None] = {}


def load(family: str = "Gotham") -> TrueTypeFont | None:
    if family in _CACHE:
        return _CACHE[family]
    path = resolve_font(family)
    font = TrueTypeFont(path) if path else None
    _CACHE[family] = font
    return font


def describe() -> dict:
    """What the harness resolved, for the audit report header."""
    out = {}
    for family in ("Gotham", "GothamBold", "RobotoMono"):
        font = load(family)
        out[family] = {
            "path": str(font.path) if font else None,
            "units_per_em": font.upem if font else None,
            "ascent": round(font.ascent, 3) if font else None,
            "descent": round(font.descent, 3) if font else None,
        }
    return out


if __name__ == "__main__":
    for family in ("Gotham", "GothamBold", "GothamMedium", "RobotoMono"):
        font = load(family)
        if not font:
            print(f"{family}: no face found")
            continue
        print(f"{family}: {font.path.name} upem={font.upem} asc={font.ascent:.3f} desc={font.descent:.3f}")
        for text in ("Fat Cat", "Silent Aim", "Decompiler", "El executor no expone getscripts()"):
            print(f"   {text!r:52} @13px = {font.text_width(text, 13):6.1f}px")
    if len(sys.argv) > 1:
        sys.exit(0)
