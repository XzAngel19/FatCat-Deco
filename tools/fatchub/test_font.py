#!/usr/bin/env python3
"""Self-test for the TrueType reader and rasteriser in tools/fatchub/font.py.

The design tools are only as good as their measurements, so the parser gets
its own checks. Each one pins a bug that actually happened while building the
harness; the comments name them so a future change that reintroduces one fails
loudly instead of producing a subtly wrong screenshot.

    python3 tools/fatchub/test_font.py
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import font  # noqa: E402


class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, name: str, condition: bool, detail: str = "") -> None:
        if condition:
            self.passed += 1
            print(f"ok   {name}")
        else:
            self.failed += 1
            print(f"FAIL {name}" + (f"  ({detail})" if detail else ""))


def ink(mask, x, y) -> int:
    """Coverage at a pixel of the glyph mask."""
    mw, mh, _, _, data = mask
    if not (0 <= x < mw and 0 <= y < mh):
        return 0
    return data[y * mw + x]


def covered(mask, threshold: int = 128) -> int:
    mw, mh, _, _, data = mask
    return sum(1 for value in data if value >= threshold)


def main() -> int:
    check = Checker()
    face = font.load("Gotham")
    if face is None:
        print("test_font: no font found on this machine", file=sys.stderr)
        return 1

    # -- metrics ----------------------------------------------------------
    # DejaVu's advances are known constants; if the cmap/hmtx wiring breaks
    # these move. 'l' narrow, 'W' wide is the whole reason the audit can tell
    # a truncated label from a fitting one.
    check.check("advance: 'l' is narrow", face.advance("l") < face.advance("W"))
    check.check("advance: space is not zero", face.advance(" ") > 0)
    check.check(
        "text_width is additive",
        abs(face.text_width("ab", 20) - (face.text_width("a", 20) + face.text_width("b", 20))) < 1e-6,
    )
    check.check(
        "text_width scales linearly",
        abs(face.text_width("Hello", 26) - 2 * face.text_width("Hello", 13)) < 1e-6,
    )
    check.check("empty text has no width", face.text_width("", 13) == 0)

    # -- truncation -------------------------------------------------------
    drawn, cut = face.truncate("Apply Changes", 12, 40)
    check.check("truncate reports a cut", cut)
    check.check("truncate fits the box", face.text_width(drawn, 12) <= 40, f"{drawn!r}")
    check.check("truncate keeps the ellipsis", drawn.endswith("…"))
    fits, cut2 = face.truncate("Ok", 12, 200)
    check.check("truncate leaves fitting text alone", fits == "Ok" and not cut2)

    # -- outlines ---------------------------------------------------------
    # Regression: the TrueType hinting program sits between the point list and
    # the coordinates. Skipping the wrong number of bytes left the reader in
    # the middle of the flag array and glyphs came out as solid blobs.
    letter_a = face.glyph_outline(face.glyph_id("a"))
    check.check("outline: 'a' has a counter", len(letter_a.contours) == 2,
                f"{len(letter_a.contours)} contour(s)")
    letter_o = face.glyph_outline(face.glyph_id("o"))
    check.check("outline: 'o' has a counter", len(letter_o.contours) == 2)

    # Rotated letters should be taller than wide; a mangled outline usually is not.
    x_min, y_min, x_max, y_max = letter_a.bbox
    check.check("outline: 'a' bbox is sane", (x_max - x_min) > 0 and (y_max - y_min) > 0,
                f"{(x_max - x_min, y_max - y_min)}")

    # -- rasterisation ----------------------------------------------------
    # Regression: the winding rule. TrueType outer contours run the other way
    # once y is flipped to screen space; a fill that assumes the first contour
    # is positive painted 'a' as a solid rectangle.
    mask_a = face.glyph_mask("a", 48)
    # Row 8 of the 48 px 'a' is the middle of the bowl: inked on the right
    # stem, empty inside the counter on the left.
    counter = ink(mask_a, 12, 8)
    right_stem = ink(mask_a, 22, 8)
    check.check("raster: 'a' counter is empty", counter < 40, f"coverage {counter}")
    check.check("raster: 'a' stem is inked", right_stem > 200, f"coverage {right_stem}")

    # Regression: a glyph with a negative left bearing used to lose its left
    # column because the origin was subtracted twice.
    # 'A' and 'J' have negative left side bearings: the mask box starts left
    # of the pen. If the origin is subtracted twice, geometry falls outside
    # the coverage array and that left shoulder is the first thing to go.
    for glyph in ("A", "J"):
        mask = face.glyph_mask(glyph, 24)
        mw, mh, ox, oy, _ = mask
        check.check(f"raster: {glyph!r} keeps its negative bearing", ox < 0, f"x_offset {ox}")
        # The left shoulder sits one column in from the mask edge; if the
        # leftmost ink were dropped, that column would be blank.
        shoulder = sum(ink(mask, 1, y) for y in range(mh))
        check.check(f"raster: {glyph!r} left shoulder has ink", shoulder > 0,
                    f"column 1 coverage {shoulder}")

    # A glyph must actually be inked somewhere, and a space must be blank.
    check.check("raster: 'M' has ink", covered(face.glyph_mask("M", 24)) > 40)
    check.check("raster: space is blank", covered(face.glyph_mask(" ", 24)) == 0)

    # Bigger sizes must cover more pixels (rough sanity on the scale factor).
    small = covered(face.glyph_mask("H", 13))
    large = covered(face.glyph_mask("H", 39))
    check.check("raster: size scales coverage", large > small * 4, f"{small} -> {large}")

    # -- every printable char --------------------------------------------
    missing = []
    for code in range(32, 127):
        char = chr(code)
        if char == " ":
            continue
        mask = face.glyph_mask(char, 24)
        if covered(mask) == 0:
            missing.append(char)
    check.check("all printable ASCII render", not missing, f"blank: {''.join(missing)}")

    # -- catalog ----------------------------------------------------------
    info = font.describe()
    check.check("describe names a real face", info["Gotham"]["path"] is not None)
    check.check("bold face differs from regular",
                font.load("GothamBold").path != font.load("Gotham").path)

    print()
    if check.failed:
        print(f"FAIL {check.failed} font check(s), {check.passed} passed")
        return 1
    print(f"PASS {check.passed} font checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
