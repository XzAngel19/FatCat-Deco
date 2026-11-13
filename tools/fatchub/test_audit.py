#!/usr/bin/env python3
"""Run the design audit against synthetic layouts and check the verdicts.

Each file in tools/fatchub/fixtures/ is a small menu with one deliberate flaw
and an `expect` list. This is how the audit rules stay honest: a rule that
stops firing shows up here long before someone notices a screenshot looks odd.

    python3 tools/fatchub/test_audit.py            # human output
    python3 tools/fatchub/test_audit.py --quiet    # exit code only

Exit code 0 when every fixture produces every expected finding, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import audit  # noqa: E402

FIXTURES = HERE / "fixtures"


def to_layout(nodes: list[dict]) -> Path:
    """Write a fixture in the same line-per-node shape layout.lua emits."""
    target = HERE / ".fixture-layout.txt"
    lines = ["LAYOUT_JSON_BEGIN"]
    for node in nodes:
        lines.append(json.dumps(node, ensure_ascii=False))
    lines.append("LAYOUT_JSON_END")
    lines.append(f"LAYOUT_NODES {len(nodes)}")
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return target


def run_one(path: Path) -> tuple[bool, list[str]]:
    spec = json.loads(path.read_text(encoding="utf-8"))
    layout = to_layout(spec["nodes"])
    nodes = audit.load(layout)

    findings = []
    for check in (audit.check_text, audit.check_contrast, audit.check_targets,
                  audit.check_spacing, audit.check_bounds):
        findings.extend(check(nodes))

    problems = []
    # An empty `expect` list is a negative test: nothing may be reported in
    # the rules the fixture targets (bounds/overlap noise from the synthetic
    # frame is allowed, text/contrast/target findings are not).
    if not spec["expect"]:
        noisy = [f for f in findings if f["rule"] in {"text-truncated", "text-overflow",
                                                     "text-clipped", "contrast",
                                                     "target-size", "out-of-bounds"}]
        for finding in noisy:
            problems.append(f'unexpected {finding["rule"]} on "{finding["what"]}": {finding["detail"]}')
        return not problems, problems
    for expected in spec["expect"]:
        hit = None
        for finding in findings:
            if finding["rule"] != expected["rule"]:
                continue
            if expected.get("severity") and finding["severity"] != expected["severity"]:
                continue
            if expected.get("contains") and expected["contains"] not in (
                finding["what"] + " " + finding["detail"]
            ):
                continue
            hit = finding
            break
        if hit is None:
            got = ", ".join(sorted({f["rule"] for f in findings})) or "nothing"
            problems.append(
                f'missing {expected["rule"]}/{expected.get("severity", "any")} '
                f'mentioning "{expected.get("contains", "*")}" (got: {got})'
            )
    return not problems, problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    fixtures = sorted(FIXTURES.glob("*.json"))
    if not fixtures:
        print("test_audit: no fixtures found", file=sys.stderr)
        return 1

    failures = 0
    for path in fixtures:
        ok, problems = run_one(path)
        spec = json.loads(path.read_text(encoding="utf-8"))
        status = "ok  " if ok else "FAIL"
        if not args.quiet:
            print(f'{status} {path.stem:22} {spec["why"]}')
        for problem in problems:
            failures += 1
            if not args.quiet:
                print(f"     {problem}")

    (HERE / ".fixture-layout.txt").unlink(missing_ok=True)
    if failures:
        print(f"FAIL {failures} expectation(s) not met")
        return 1
    print(f"PASS {len(fixtures)} audit fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
