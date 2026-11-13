#!/usr/bin/env python3
"""Refuse a project module whose *body* touches a dependency it is given later.

Every module under src/project/ has two halves:

    local Core, Signal          -- forward declarations, nil for now
    Spy = {}                    -- the module's own table, built now
    function Spy.start() ... end
    return function(core, signal)
        Core, Signal = core, signal   -- only now do they exist
        return Spy
    end

The body runs when the bundle is *built*; the factory runs when the project is
*booted*. So a body that reads `Core` at the top level captures nil and the
module dies at boot with "attempt to index nil" — a bug the type checker cannot
see, because the name is declared and simply not assigned yet.

The rule this enforces: a name forward-declared with `local` and assigned only
inside the factory is a *dependency*, and the module body may not read it. The
module's own table (`Spy = {}`) is not a dependency even though it is declared
in the same `local` line, because the body assigns it itself.

Function bodies are skipped, because `function Spy.mount() Core:OnDestroy(...)
end` is legal: it runs after the factory, not before. This codebase indents
every block, so "starts at column 0" is a reliable test for "is at module
level", and the check stays readable instead of turning into a Lua parser.

Also refuses a module with no factory at all, except the two that are plain
tables (FatCatSignal, FatCatCore).

    python3 tools/lint_module_body.py            # check the tree
    python3 tools/lint_module_body.py --verbose  # list every module checked

Exit code 0 when clean, 1 with one line per problem.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "src" / "project"

# Modules that are tables rather than factories: the two the rest is built on.
TABLE_MODULES = {"FatCatSignal", "FatCatCore"}

FACTORY = re.compile(r"^return function\s*\(([^)]*)\)")
DECLARE = re.compile(r"^local\s+([A-Za-z_][\w, \t]*?)\s*$")
# `Name = ...`, `Name.field = ...`, `Name.field.deeper = ...`
SELF_ASSIGN = re.compile(r"^([A-Za-z_]\w*)\s*(?:\.[A-Za-z_]\w*\s*)*=(?!=)")
NOT_A_STATEMENT = re.compile(r"^(?:end\b|\}|\{|\]|\)|else\b|elseif\b|until\b|return\b)")
# `local x = expr` at module level: the declaration is fine, the right-hand
# side is where a dependency would be read. Matching it separately is what
# catches `local early = Core.env.foo`, the exact bug this lint exists for.
LOCAL_ASSIGN = re.compile(r"^local\s+[A-Za-z_][\w, \t]*=(?!=)\s*(.*)$")


def check(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()

    factory_at = None
    for index, line in enumerate(lines):
        if FACTORY.match(line):
            factory_at = index
            break

    stem = path.stem
    if factory_at is None:
        if stem in TABLE_MODULES:
            return []
        return [f"{path.relative_to(ROOT)}: no `return function(...)` factory"]

    body = lines[:factory_at]
    problems: list[str] = []

    # Everything the body forward-declares with `local`, and everything the body
    # assigns to itself at module level.
    declared: set[str] = set()
    for line in body:
        match = DECLARE.match(line)
        if match:
            declared.update(part.strip() for part in match.group(1).split(",") if part.strip())

    own: set[str] = set()
    for line in body:
        if not line or line[0] in " \t" or line.lstrip().startswith("--"):
            continue
        match = SELF_ASSIGN.match(line)
        if match:
            own.add(match.group(1))
    # A dependency is something awaited from the factory. Anything the body
    # builds itself, or declares as a plain local, is not.
    dependencies = declared - own - {stem}

    if not dependencies:
        return []

    for number, line in enumerate(body, 1):
        if not line or line[0] in " \t":
            continue  # inside a block or a function: not module level
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            continue
        if NOT_A_STATEMENT.match(stripped):
            continue
        if stripped.startswith("function"):
            continue  # a definition; its body runs after the factory
        # For a module-level `local`, only the value is a read; for everything
        # else the whole line is.
        local_assign = LOCAL_ASSIGN.match(stripped)
        if not local_assign and stripped.startswith("local "):
            continue  # a bare declaration (`local Core, Signal`): names only
        if local_assign and not local_assign.group(1):
            continue  # `local x =` with the value on the next line; rare, and
                      # the next line is indented so this stays conservative
        target = local_assign.group(1) if local_assign else line
        for dependency in sorted(dependencies):
            if re.search(rf"\b{re.escape(dependency)}\b", target):
                problems.append(
                    f"{path.relative_to(ROOT)}:{number}: the module body reads `{dependency}`, "
                    f"which is nil until the factory runs -> {stripped}"
                )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description="Check that module bodies do not read their dependencies early.")
    parser.add_argument("--verbose", action="store_true", help="list every module checked")
    args = parser.parse_args()

    if not PROJECT.is_dir():
        print(f"lint_module_body: {PROJECT.relative_to(ROOT)} is missing")
        return 1

    modules = sorted(PROJECT.rglob("*.lua"))
    if not modules:
        print("lint_module_body: no modules found")
        return 1

    problems: list[str] = []
    for path in modules:
        found = check(path)
        problems.extend(found)
        if args.verbose:
            print(f"{'FAIL' if found else 'ok  '} {path.relative_to(ROOT)}")

    if problems:
        for problem in problems:
            print("FAIL " + problem)
        return 1

    print(f"PASS {len(modules)} module bodies keep their dependencies for the factory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
