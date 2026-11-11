#!/usr/bin/env bash
# Reproducible checks for the Fat Cat Decompiler tree.
#
#   bash tools/validate.sh              # full gate
#   bash tools/validate.sh --quick      # skip the analyzer (compile + bytecode only)
#
# Everything runs from the vendored toolchain (tools/luau), so a fresh clone or a
# wiped sandbox needs node and nothing else: no npm install, no network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p build

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# --- toolchain ------------------------------------------------------------
if [ ! -x tools/luau/bin/luau ] || [ ! -d tools/luau/node_modules/@luau-rs/luau ] \
    || [ ! -d tools/luau/node_modules/darklua-wasm ]; then
    if [ -f tools/luau/vendor/luau-rs-luau-0.739.0.tgz ]; then
        bash tools/luau/setup.sh >/dev/null
    fi
fi
LUAU="${LUAU:-tools/luau/bin/luau}"
LUAU_COMPILE="${LUAU_COMPILE:-tools/luau/bin/luau-compile}"
for tool in "$LUAU" "$LUAU_COMPILE"; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing Luau tool: $tool (run bash tools/luau/setup.sh)" >&2
        exit 1
    }
done
export LUAU
export PYTHONUTF8=1

# --- sources --------------------------------------------------------------
# Every Lua/Luau script outside the unpacked tooling has to compile. The
# `declare ...` definition files are not scripts and are excluded by name.
sources=0
while IFS= read -r -d '' source; do
    case "$source" in *.d.luau) continue ;; esac
    "$LUAU_COMPILE" "$source" >/dev/null
    sources=$((sources + 1))
done < <(find . -path ./tools/luau/node_modules -prune -o -path ./tools/luau/vendor -prune -o \
    -path ./.git -prune -o -path ./build -prune -o \
    \( -name '*.lua' -o -name '*.luau' \) -print0)
if [ "$sources" -eq 0 ]; then
    echo "PASS no loose Lua/Luau sources to compile (Cobalt.txt is gated below)"
else
    echo "PASS $sources Lua/Luau source(s) compile"
fi

# Cobalt is the decompiler itself, stored as a .txt bundle. It is the one file
# whose bytecode the rest of the work reads, so it gets its own gates.
[ -f Cobalt.txt ] || { echo "Cobalt.txt is missing" >&2; exit 1; }
"$LUAU_COMPILE" Cobalt.txt >/dev/null
echo "PASS Cobalt.txt compiles"

tools/luau/bin/luau-validate Cobalt.txt >build/cobalt.bytecode.log 2>&1 || {
    cat build/cobalt.bytecode.log
    exit 1
}
tail -1 build/cobalt.bytecode.log

tools/luau/bin/luau-disasm Cobalt.txt --stats >build/cobalt.prototypes.log 2>&1 || {
    cat build/cobalt.prototypes.log
    exit 1
}
prototypes="$(awk 'NR>2 && NF' build/cobalt.prototypes.log | wc -l | tr -d ' ')"
[ "$prototypes" -gt 0 ] || { cat build/cobalt.prototypes.log; exit 1; }
echo "PASS bytecode disassembly: $prototypes prototypes"

# --- static analysis ------------------------------------------------------
if [ "$QUICK" = 0 ]; then
    node tools/luau/analyze.mjs --baseline --quiet >build/analyze.txt 2>build/analyze.summary.txt || {
        cat build/analyze.txt
        echo "analyze: new type errors outside tools/luau/analyze-baseline.json" >&2
        exit 1
    }
    tail -1 build/analyze.summary.txt
fi

# --- release artifact -----------------------------------------------------
node tools/luau/minify.mjs Cobalt.txt -o build/Cobalt.min.lua 2>build/minify.log
cat build/minify.log
tools/luau/bin/luau-validate build/Cobalt.min.lua >build/minify.validate.log 2>&1 || {
    cat build/minify.validate.log
    exit 1
}
echo "PASS release artifact: minified Cobalt still validates"

# --- FatCat Hub -------------------------------------------------------------
# The menu is the only real Luau program in the tree, so it gets its own gates:
# it compiles, the analyzer is clean (no baseline entry hides it), and the
# mocked-DataModel harness passes.
if [ -f src/FatCatHub.lua ]; then
    # The specs are compiled by their own harnesses, which wrap them correctly.
    "$LUAU_COMPILE" src/FatCatHub.lua src/FatCatHub.loader.lua src/FatCatHub.project.lua >/dev/null
    node tools/luau/analyze.mjs --quiet src/FatCatHub.lua src/FatCatHub.loader.lua \
        src/FatCatHub.project.lua >build/fatchub.analyze.txt 2>&1 || {
        cat build/fatchub.analyze.txt
        exit 1
    }
    bash tools/test_fatchub.sh >build/fatchub.test.log 2>&1 || {
        tail -20 build/fatchub.test.log
        exit 1
    }
    grep -E "^PASS" build/fatchub.test.log
    bash tools/test_fatchub_loader.sh >build/fatchub.loader.test.log 2>&1 || {
        tail -20 build/fatchub.loader.test.log
        exit 1
    }
    grep -E "^PASS" build/fatchub.loader.test.log
fi

# --- toolchain self-test --------------------------------------------------
python3 tools/test_luau_toolchain.py
echo "PASS toolchain self-test"
