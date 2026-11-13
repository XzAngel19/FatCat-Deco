#!/usr/bin/env python3
"""Design audit for a Fat Cat layout dump.

The harness can already say "the window is 460x560 and this label sits at
x=445". This tool answers the questions a menu author actually has:

  * which labels are cut off, and by how many pixels
  * which rows have text taller than the row itself
  * which text is unreadable against what is behind it
  * where the spacing is off-grid, or two elements are suspiciously close
  * which interactive targets are too small to hit

Everything comes from the same JSON the renderer paints, so an audit and a
screenshot never disagree.

    python3 tools/fatchub/audit.py build/layout.txt
    python3 tools/fatchub/audit.py build/layout.txt --json build/audit.json --strict
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import font as fontmod  # noqa: E402
import render as rendermod  # noqa: E402

# --------------------------------------------------------------------------
# Rules. Each entry documents the threshold and why it is the threshold.
# --------------------------------------------------------------------------
RULES = {
    "min_target": 24.0,        # px, smaller than this and a touch mis-taps
    "min_contrast": 3.0,       # WCAG AA for large/incidental text, this is a HUD
    "text_margin": 2.0,        # px between a glyph box and its container edge
    "min_gap": 3.0,            # px between sibling cards; 0 means they touch
    "spacing_grid": 1.0,       # px; anything not integral is a rounding bug
    "label_padding": 2.0,      # px of slack before a label counts as tight
}

TEXT_CLASSES = {"TextLabel", "TextButton", "TextBox"}
INTERACTIVE = {"TextButton", "TextBox"}


def luminance(color) -> float:
    def channel(value: float) -> float:
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(max(0.0, min(1.0, c))) for c in color[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b) -> float:
    la, lb = luminance(a), luminance(b)
    high, low = max(la, lb), min(la, lb)
    return (high + 0.05) / (low + 0.05)


def load(path: Path):
    nodes = []
    inside = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "LAYOUT_JSON_BEGIN":
            inside = True
            continue
        if line == "LAYOUT_JSON_END":
            inside = False
            continue
        if inside and line.startswith("{"):
            nodes.append(json.loads(line))
    return nodes


def inside(node, x, y) -> bool:
    return node["x"] <= x <= node["x"] + node["w"] and node["y"] <= y <= node["y"] + node["h"]


def visible(node) -> bool:
    if node.get("transparency", 0) >= 1 and not node.get("text"):
        return False
    return True


def ancestry(nodes):
    """node -> list of nodes that contain it, innermost first."""
    parents = {}
    for node in nodes:
        candidates = []
        for other in nodes:
            if other is node:
                continue
            if (other["x"] <= node["x"] + 0.5 and other["y"] <= node["y"] + 0.5
                    and other["x"] + other["w"] >= node["x"] + node["w"] - 0.5
                    and other["y"] + other["h"] >= node["y"] + node["h"] - 0.5
                    and (other["w"] > node["w"] or other["h"] > node["h"])):
                candidates.append(other)
        candidates.sort(key=lambda n: n["w"] * n["h"])
        parents[id(node)] = candidates
    return parents


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------


def check_text(nodes):
    """Fit, clipping, and vertical overflow for every label."""
    issues = []
    parents = ancestry(nodes)
    for node in nodes:
        text = node.get("text")
        if not text:
            continue
        face = fontmod.load(node.get("font", "Gotham")) or fontmod.load("Gotham")
        if face is None:
            continue
        size = float(node.get("size", 12))
        box_w, box_h = node["w"], node["h"]
        label = text if len(text) <= 42 else text[:39] + "..."
        where = f'{node.get("name") or "label"}: "{label}"'

        # 1. Does it fit horizontally? Wrapped labels wrap; the rest truncate.
        if node.get("wrap"):
            words = text.split()
            longest = max((face.text_width(word, size) for word in words), default=0)
            if longest > box_w + 0.5:
                issues.append({
                    "rule": "text-overflow",
                    "severity": "error",
                    "what": where,
                    "detail": f"word wider than its box ({longest:.0f}px in {box_w:.0f}px)",
                    "box": [node["x"], node["y"], box_w, box_h],
                })
            lines = _wrap_lines(face, text, size, box_w)
            needed = face.line_height(size) * max(1, len(lines))
            if needed > box_h + 0.5:
                issues.append({
                    "rule": "text-overflow",
                    "severity": "warning",
                    "what": where,
                    "detail": f"wraps to {len(lines)} line(s), needs {needed:.0f}px, has {box_h:.0f}px",
                    "box": [node["x"], node["y"], box_w, box_h],
                })
            continue

        if node.get("scrolls"):
            # Inside a scrolling viewport: the text runs on and the user drags
            # to it. Not a truncation, not a clipping bug.
            continue

        drawn, cut = face.truncate(text, size, box_w)
        if cut:
            missing = face.text_width(text, size) - box_w
            issues.append({
                "rule": "text-truncated",
                "severity": "warning",
                "what": where,
                "detail": f'cuts to "{drawn}" at {box_w:.0f}px, {missing:.0f}px short',
                "box": [node["x"], node["y"], box_w, box_h],
            })

        # 2. Is the glyph box taller than the label? Roblox clips it.
        glyph_h = face.line_height(size)
        if glyph_h > box_h + 1.0:
            issues.append({
                "rule": "text-overflow",
                "severity": "warning",
                "what": where,
                "detail": f"line box {glyph_h:.0f}px in a {box_h:.0f}px label; descenders clip",
                "box": [node["x"], node["y"], box_w, box_h],
            })

        # 3. Does any clipping ancestor cut the label? `clip` in the dump is
        # the chain of ancestors that hide overflow, so a label whose own rect
        # pokes out of one of them loses pixels on screen.
        for clip in node.get("clip") or []:
            if clip.get("scroll"):
                continue
            right = clip["x"] + clip["w"]
            bottom = clip["y"] + clip["h"]
            if node["x"] + box_w > right + 0.5:
                over = node["x"] + box_w - right
                issues.append({
                    "rule": "text-clipped",
                    "severity": "error",
                    "what": where,
                    "detail": (
                        f"label extends {over:.0f}px past its clipping ancestor "
                        f"(x {node['x']:.0f}..{node['x'] + box_w:.0f} vs {clip['x']:.0f}..{right:.0f})"
                    ),
                    "box": [node["x"], node["y"], box_w, box_h],
                })
                break
            # Half a pixel is float noise from scale/offset resolution.
            if node["y"] + box_h > bottom + 0.5:
                over = node["y"] + box_h - bottom
                issues.append({
                    "rule": "text-clipped",
                    "severity": "error",
                    "what": where,
                    "detail": (
                        f"label extends {over:.0f}px past its clipping ancestor "
                        f"(y {node['y']:.0f}..{node['y'] + box_h:.0f} vs {clip['y']:.0f}..{bottom:.0f})"
                    ),
                    "box": [node["x"], node["y"], box_w, box_h],
                })
                break
    return issues


def _wrap_lines(face, text, size, width):
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


def check_contrast(nodes):
    """Sample what each label sits on and compare luminance."""
    issues = []
    order = sorted(nodes, key=lambda node: node.get("z", 1))
    labels = [node for node in order if node.get("text")]
    if not labels:
        return issues

    # Paint the surfaces once, then read the pixel under each label centre.
    canvas = rendermod.Canvas(rendermod.WIDTH, rendermod.HEIGHT)
    rendermod.draw_surfaces(canvas, [node for node in order if not node.get("text")])

    for node in labels:
        alpha = (node.get("text_opacity", node.get("opacity", 1.0)) or 1.0) * (
            node.get("group_alpha", 1.0) or 1.0
        )
        if alpha <= 0.05:
            continue
        # Background: median of a few points in the label box, skipping the
        # glyphs themselves is overkill, so sample just outside them.
        px = int(min(canvas.width - 1, max(0, node["x"] + node["w"] / 2)))
        py = int(min(canvas.height - 1, max(0, node["y"] + node["h"] / 2)))
        index = (py * canvas.width + px) * 3
        background = canvas.pixels[index : index + 3]
        foreground = node.get("color") or [1, 1, 1]
        ratio = contrast(foreground, background)
        if ratio < RULES["min_contrast"]:
            issues.append({
                "rule": "contrast",
                "severity": "error",
                "what": f'"{node["text"][:40]}"',
                "detail": (
                    f"{ratio:.2f}:1 against its surface "
                    f"(rgba {foreground[0]:.2f},{foreground[1]:.2f},{foreground[2]:.2f} on "
                    f"{background[0]:.2f},{background[1]:.2f},{background[2]:.2f}); "
                    f"needs {RULES['min_contrast']}:1"
                ),
                "box": [node["x"], node["y"], node["w"], node["h"]],
            })
    return issues


def check_targets(nodes):
    issues = []
    parents = ancestry(nodes)
    for node in nodes:
        if node["class"] not in INTERACTIVE:
            continue
        if node.get("transparency", 0) >= 1 and node["class"] != "TextBox":
            continue
        # A button that is a big wrapper (drag surface, card) is fine; only
        # flag the ones small enough to mis-tap.
        if node["w"] >= RULES["min_target"] and node["h"] >= RULES["min_target"]:
            continue
        issues.append({
            "rule": "target-size",
            "severity": "warning",
            "what": node.get("name") or node["class"],
            "detail": (
                f'{node["w"]:.0f}x{node["h"]:.0f}px, below the '
                f'{RULES["min_target"]:.0f}px minimum for a pointer target'
            ),
            "box": [node["x"], node["y"], node["w"], node["h"]],
        })
    return issues


def check_spacing(nodes):
    """Sibling gaps inside a shared container: touching rows and off-grid px."""
    issues = []
    parents = ancestry(nodes)
    groups: dict[int, list] = {}
    for node in nodes:
        if node.get("text") or node["class"] not in {"Frame", "TextButton", "TextBox"}:
            continue
        chain = parents.get(id(node)) or []
        if not chain:
            continue
        key = id(chain[0])
        groups.setdefault(key, []).append(node)

    seen = set()
    for key, members in groups.items():
        members.sort(key=lambda n: (round(n["y"], 1), round(n["x"], 1)))
        for index in range(len(members) - 1):
            first, second = members[index], members[index + 1]
            if abs(first["x"] - second["x"]) > 1.0:
                continue
            gap = second["y"] - (first["y"] + first["h"])
            if gap < 0.5:
                continue  # intentional overlap (glow rails, badges)
            pair = (round(first["x"]), round(first["y"]), round(second["y"]))
            if gap < RULES["min_gap"] and pair not in seen:
                seen.add(pair)
                issues.append({
                    "rule": "tight-spacing",
                    "severity": "note",
                    "what": f'"{second.get("name")}" under "{first.get("name")}"',
                    "detail": f"{gap:.1f}px gap; rows read as one block below {RULES['min_gap']:.0f}px",
                    "box": [second["x"], second["y"], second["w"], second["h"]],
                })
            off = abs(gap - round(gap))
            if off > RULES["spacing_grid"]:
                issues.append({
                    "rule": "off-grid",
                    "severity": "note",
                    "what": f'gap above "{second.get("name")}"',
                    "detail": f"{gap:.2f}px; layout should land on whole pixels",
                    "box": [second["x"], second["y"], second["w"], second["h"]],
                })
    return issues


def check_bounds(nodes, width=rendermod.WIDTH, height=rendermod.HEIGHT):
    issues = []
    for node in nodes:
        if node["class"] == "ScreenGui" or not visible(node):
            continue
        if node["x"] < -1 or node["y"] < -1 or node["x"] + node["w"] > width + 1 or node["y"] + node["h"] > height + 1:
            issues.append({
                "rule": "out-of-bounds",
                "severity": "warning",
                "what": node.get("name") or node["class"],
                "detail": f'({node["x"]:.0f},{node["y"]:.0f}) {node["w"]:.0f}x{node["h"]:.0f} leaves the screen',
                "box": [node["x"], node["y"], node["w"], node["h"]],
            })
    return issues


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
SEVERITY_ORDER = {"error": 0, "warning": 1, "note": 2}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layout", type=Path)
    parser.add_argument("--json", type=Path, help="write the findings as JSON")
    parser.add_argument("--strict", action="store_true", help="warnings fail too")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if not args.layout.exists():
        print(f"audit: {args.layout} not found", file=sys.stderr)
        return 2
    nodes = load(args.layout)
    if not nodes:
        print("audit: no nodes parsed", file=sys.stderr)
        return 1

    findings = []
    for check in (check_text, check_contrast, check_targets, check_spacing, check_bounds):
        findings.extend(check(nodes))
    findings.sort(key=lambda f: (SEVERITY_ORDER.get(f["severity"], 9), f["rule"], f["what"]))

    counts = Counter(finding["severity"] for finding in findings)
    if args.json:
        args.json.write_text(json.dumps({
            "layout": str(args.layout),
            "nodes": len(nodes),
            "counts": dict(counts),
            "findings": findings,
        }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    if not args.quiet:
        window = next((n for n in nodes if n.get("name") == "Window"), None)
        size = f'{window["w"]:.0f}x{window["h"]:.0f}' if window else "?"
        print(f"audit: {len(nodes)} nodes, window {size}, "
              f'{counts.get("error", 0)} error(s) / {counts.get("warning", 0)} warning(s) / '
              f'{counts.get("note", 0)} note(s)')
        for finding in findings:
            marker = {"error": "ERR ", "warning": "WARN", "note": "note"}[finding["severity"]]
            print(f"  {marker}  [{finding['rule']}] {finding['what']}")
            print(f"        {finding['detail']}")

    if counts.get("error"):
        return 1
    if args.strict and counts.get("warning"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
