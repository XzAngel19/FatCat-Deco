#!/usr/bin/env bash
# Rebuild the Luau toolchain from the tarballs committed in this branch.
#
#   bash tools/luau/setup.sh            # unpack / repair, idempotent
#   bash tools/luau/setup.sh --verify   # also smoke-test every tool
#
# The sandbox (and any fresh clone) has no Luau binary, no node_modules and no
# guarantee that npm is reachable. Every package is pinned and vendored under
# vendor/, so this script never touches the network. Layout it produces:
#
#   node_modules/@luau-rs/luau        Luau compiler + runtime (wasm, v739)
#   node_modules/@luau-rs/luau/analysis  the same front end as luau-analyze
#   node_modules/valibot              @luau-rs/luau's only dependency
#   node_modules/@johnnymorganz/stylua  StyLua 2.6 as a library
#   node_modules/darklua-wasm         DarkLua rule engine (wasm)
#   bin/luau, bin/luau-compile        runtime + syntax gate used by validate.sh
#   bin/luau-analyze                  type check + lints over src/
#   bin/luau-format                   StyLua over src/
#   bin/luau-minify                   DarkLua (release artifact)
#   bin/luau-disasm                    prototype/opcode/constant listing
#   bin/luau-validate                 bytecode container integrity check
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BIN_DIR="bin"
VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1

command -v node >/dev/null 2>&1 || {
    echo "node is required to run the wasm Luau toolchain" >&2
    exit 1
}

# unpack <tarball glob> <module dir>
unpack() {
    local tarball="$1" target="$2"
    if [ ! -f "$tarball" ]; then
        echo "missing $tarball: the vendored package was not committed" >&2
        return 1
    fi
    if [ -f "$target/package.json" ]; then
        return 0
    fi
    mkdir -p "$target"
    # --strip-components=1 removes the leading "package/" directory.
    tar -xzf "$tarball" -C "$target" --strip-components=1
}

unpack vendor/luau-rs-luau-0.739.0.tgz node_modules/@luau-rs/luau
unpack vendor/valibot-1.5.0.tgz node_modules/valibot
unpack vendor/johnnymorganz-stylua-2.6.0.tgz node_modules/@johnnymorganz/stylua
unpack vendor/darklua-wasm-0.1.0.tgz node_modules/darklua-wasm

mkdir -p "$BIN_DIR"
write_bin() {
    local name="$1" script="$2"
    cat >"$BIN_DIR/$name" <<EOF
#!/usr/bin/env bash
exec node "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/$script" "\$@"
EOF
    chmod +x "$BIN_DIR/$name"
}

write_bin luau run.mjs
write_bin luau-compile compile.mjs
write_bin luau-analyze analyze.mjs
write_bin luau-format format.mjs
write_bin luau-minify minify.mjs
write_bin luau-disasm disasm.mjs
write_bin luau-validate validate-bytecode.mjs

if [ "$VERIFY" = 1 ]; then
    echo "verifying toolchain"
    printf 'print("luau ok")\n' >"$BIN_DIR/.smoke.luau"
    "$BIN_DIR/luau" "$BIN_DIR/.smoke.luau"
    printf 'local x: number = 1\nprint(x)\n' >"$BIN_DIR/.smoke.lua"
    "$BIN_DIR/luau-compile" "$BIN_DIR/.smoke.lua"
    echo "compile ok"
    # Definition files (`declare ...`) are not Luau scripts, so the smoke test
    # formats a real snippet instead of a .d.luau.
    node -e "
        import('./format.mjs').then((m) => console.log('stylua ok:', JSON.stringify(m.formatSource('local x=1'))));
        import('./minify.mjs').then((m) => console.log('darklua ok:', m.ruleNames().length + ' rules'));
    "
    rm -f "$BIN_DIR/.smoke.luau" "$BIN_DIR/.smoke.lua"
fi

echo "Luau toolchain ready: $BIN_DIR/{luau,luau-compile,luau-analyze,luau-format,luau-minify,luau-disasm,luau-validate}"
