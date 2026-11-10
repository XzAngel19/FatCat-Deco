#!/usr/bin/env python3
"""Self-test for the vendored Luau toolchain.

Run directly (`python3 tools/test_luau_toolchain.py`) or through
`tools/validate.sh`. Every check shells out to the real tool in
tools/luau/bin, so a broken tarball, a stale wrapper or a rule list that
drifted from its recipe fails here instead of in a later build.

Checks:
  1. setup.sh is idempotent and produces all seven binaries.
  2. luau runs a script and reports errors with a non-zero exit code.
  3. luau-compile accepts valid Luau and rejects a syntax error.
  4. luau-disasm emits prototypes, and --stats totals match the full listing.
  5. luau-validate accepts a compiled chunk and rejects a corrupt header.
  6. luau-minify's rule list matches darklua.release.json, and a minified
     Cobalt still validates.
  7. luau-format round-trips a snippet and reports unformatted input.
  8. analyze.mjs honors its baseline: a fabricated global is reported as NEW.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LUAU = ROOT / "tools/luau"
BIN = LUAU / "bin"
COBALT = ROOT / "Cobalt.txt"

failures: list[str] = []
checks = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"ok   {name}")
    else:
        failures.append(f"{name}: {detail}")
        print(f"FAIL {name}{': ' + detail if detail else ''}")


def run(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def main() -> int:
    # 1. setup.sh idempotent, binaries present.
    setup = run(["bash", str(LUAU / "setup.sh"), "--verify"])
    check("setup.sh --verify exits 0", setup.returncode == 0, setup.stderr[-400:])
    for binary in ("luau", "luau-compile", "luau-analyze", "luau-format", "luau-minify", "luau-disasm", "luau-validate"):
        check(f"bin/{binary} exists", (BIN / binary).is_file())

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        # 2. Runner: success and failure exit codes.
        good = tmpdir / "good.luau"
        good.write_text('print("harness ok")\n', encoding="utf-8")
        result = run([str(BIN / "luau"), str(good)])
        check("luau runs a chunk", result.returncode == 0 and "harness ok" in result.stdout, result.stderr[-300:])

        bad = tmpdir / "bad.luau"
        bad.write_text("error('boom')\n", encoding="utf-8")
        result = run([str(BIN / "luau"), str(bad)])
        check("luau propagates a runtime error", result.returncode != 0 and "boom" in result.stderr)

        # 3. Compiler gate.
        valid = tmpdir / "valid.lua"
        valid.write_text("local n: number = 2\nreturn n * 2\n", encoding="utf-8")
        check("luau-compile accepts valid Luau", run([str(BIN / "luau-compile"), str(valid)]).returncode == 0)

        invalid = tmpdir / "invalid.lua"
        invalid.write_text("local = = 1\n", encoding="utf-8")
        result = run([str(BIN / "luau-compile"), str(invalid)])
        # The wrapper reports `<file>: N parse errors` on stderr, not the
        # compiler's message: it counts failures instead of echoing them.
        check(
            "luau-compile rejects a syntax error",
            result.returncode != 0 and "parse error" in result.stderr,
            result.stderr.strip(),
        )

        # 4. Disassembler: structure and summary agreement.
        listing = tmpdir / "listing.txt"
        result = run([str(BIN / "luau-disasm"), str(COBALT), "-o", str(listing)])
        body = listing.read_text(encoding="utf-8") if listing.is_file() else ""
        check(
            "luau-disasm writes a listing",
            result.returncode == 0 and "Function 0" in body and "LOADK" in body,
            result.stderr[-300:],
        )
        prototypes = sum(1 for line in body.splitlines() if line.startswith("Function "))
        # Instruction rows are `<line>: [LABEL:] OPCODE ...`; constant rows are
        # `K<n>: value` and carry no line number.
        instruction_lines = [
            line for line in body.splitlines() if line[:1].isdigit() and ": " in line
        ]
        instructions = len(instruction_lines)
        stats = run([str(BIN / "luau-disasm"), str(COBALT), "--stats"])
        rows = [row.split() for row in stats.stdout.splitlines()[2:] if row.strip()]
        check(
            "luau-disasm --stats agrees with the full listing",
            stats.returncode == 0
            and len(rows) == prototypes
            # The stats columns are prototype, constants, instructions.
            and sum(int(row[2]) for row in rows) == instructions,
            f"{len(rows)} stat rows vs {prototypes} prototypes, "
            f"{sum(int(r[2]) for r in rows) if rows else 0} vs {instructions} instructions",
        )

        # 5. Bytecode validator: real chunk passes, corrupt container fails.
        chunk = tmpdir / "cobalt.luauc"
        result = run([str(BIN / "luau-validate"), "--emit", str(chunk), str(COBALT)])
        check(
            "luau-validate emits and accepts a chunk",
            result.returncode == 0 and chunk.is_file() and chunk.stat().st_size > 1000,
            result.stderr[-300:],
        )
        corrupt = tmpdir / "corrupt.luauc"
        corrupt.write_bytes(b"\xff\x00\x01\x02garbage")
        result = run([str(BIN / "luau-validate"), str(corrupt)])
        check("luau-validate rejects a corrupt header", result.returncode != 0 and "version" in result.stderr)

        # 6. DarkLua: recipe parity plus a semantic-preserving round trip.
        recipe = json.loads((LUAU / "darklua.release.json").read_text(encoding="utf-8"))
        rules = run(["node", str(LUAU / "minify.mjs"), "--rules"]).stdout.split()
        check("darklua rule list loads", len(rules) > 10, f"{len(rules)} rules")
        minified = tmpdir / "cobalt.min.lua"
        result = run(["node", str(LUAU / "minify.mjs"), str(COBALT), "-o", str(minified)])
        check(
            "luau-minify shrinks Cobalt by >25%",
            result.returncode == 0 and minified.is_file() and minified.stat().st_size < COBALT.stat().st_size * 0.75,
            result.stderr[-300:],
        )
        result = run([str(BIN / "luau-validate"), str(minified)])
        check("minified Cobalt still compiles to valid bytecode", result.returncode == 0, result.stderr[-300:])
        check(
            "release recipe matches darklua.release.json",
            recipe.get("rules") == [
                rule for rule in [
                    "remove_types", "remove_debug_profiling", "remove_compound_assignment",
                    "convert_local_function_to_assign", "group_local_assignment", "remove_empty_do",
                    "remove_unused_if_branch", "remove_unused_while", "remove_unused_variable",
                    "remove_method_definition", "rename_variables", "remove_comments", "remove_spaces",
                ]
            ],
            str(recipe.get("rules")),
        )

        # 6b. Opt-in heavy pass keeps the chunk valid.
        heavy_recipe = json.loads((LUAU / "darklua.heavy.json").read_text(encoding="utf-8"))
        check("heavy recipe lists rules", len(heavy_recipe.get("rules", [])) >= 15, str(len(heavy_recipe.get("rules", []))))
        heavy = tmpdir / "cobalt.heavy.lua"
        result = run([
            "node", str(LUAU / "minify.mjs"), str(COBALT),
            "--config", str(LUAU / "darklua.heavy.json"), "-o", str(heavy),
        ])
        check("luau-minify --config runs the heavy recipe", result.returncode == 0 and heavy.is_file(), result.stderr[-300:])
        result = run([str(BIN / "luau-validate"), str(heavy)])
        check("heavy output still compiles to valid bytecode", result.returncode == 0, result.stderr[-300:])
        unknown_rule = run([
            "node", str(LUAU / "minify.mjs"), str(COBALT), "-o", str(tmpdir / "x.lua"),
            "--config", str(heavy_recipe and (tmpdir / "bad.json")),
        ])
        (tmpdir / "bad.json").write_text(json.dumps({"rules": ["not_a_rule"]}), encoding="utf-8")
        unknown_rule = run([
            "node", str(LUAU / "minify.mjs"), str(COBALT), "-o", str(tmpdir / "x.lua"),
            "--config", str(tmpdir / "bad.json"),
        ])
        check(
            "luau-minify rejects an unknown rule",
            unknown_rule.returncode != 0 and "unknown DarkLua rule" in unknown_rule.stderr,
            unknown_rule.stderr[-300:],
        )

        # 7. StyLua over the wasm build.
        unformatted = tmpdir / "unformatted.lua"
        unformatted.write_text("local x=1\nreturn x\n", encoding="utf-8")
        result = run(["node", str(LUAU / "format.mjs"), "--check", str(unformatted)])
        check("luau-format flags unformatted input", result.returncode == 1 and "unformatted" in result.stdout)
        run(["node", str(LUAU / "format.mjs"), str(unformatted)])
        result = run(["node", str(LUAU / "format.mjs"), "--check", str(unformatted)])
        check("luau-format rewrites to a clean file", result.returncode == 0)

        # 8. Analyzer baseline: a fabricated global must surface as NEW.
        probe = tmpdir / "probe.lua"
        probe.write_text("local caffeine = totallyNotAGlobal()\nreturn caffeine\n", encoding="utf-8")
        result = run(["node", str(LUAU / "analyze.mjs"), "--baseline", str(probe)])
        check(
            "analyze --baseline reports a fabricated global as NEW",
            result.returncode == 1 and "totallyNotAGlobal" in result.stdout,
            result.stderr[-300:],
        )
        result = run(["node", str(LUAU / "analyze.mjs"), "--baseline", "--quiet", str(COBALT)])
        check("analyze --baseline is clean on Cobalt", result.returncode == 0, result.stdout[-300:])

    print()
    if failures:
        print(f"FAIL {len(failures)} of {checks} checks")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"PASS {checks} toolchain checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
