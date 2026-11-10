#!/usr/bin/env node
// Bytecode disassembler for the Fat Cat Decompiler work.
//
//   node tools/luau/disasm.mjs Cobalt.txt                 # full listing to stdout
//   node tools/luau/disasm.mjs Cobalt.txt --stats         # per-function summary only
//   node tools/luau/disasm.mjs Cobalt.txt --constants     # constants + strings only
//   node tools/luau/disasm.mjs Cobalt.txt -o build/bc.txt
//   node tools/luau/disasm.mjs --bytecode path/file.luauc # dump a compiled chunk
//
// Why this exists: a decompiler is read from the bytecode, not from the source.
// `luau-compile` only answers "does it parse"; this prints the prototypes,
// opcodes, constants and upvalue counts the decompiler actually consumes, and
// it prints the same shape for a source file and for a `.luauc` bytecode blob.
import { readFileSync, writeFileSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { Lua } from '@luau-rs/luau';

const HERE = resolve(import.meta.dirname, '..', '..');

function usage() {
    console.error(
        'usage: node tools/luau/disasm.mjs <file.lua|.luau|.txt> [--stats|--constants] [-o out.txt]\n' +
            '       node tools/luau/disasm.mjs --bytecode <file.luauc> [--stats] [-o out.txt]',
    );
    process.exitCode = 2;
}

/** argv -> { input, out, mode, bytecode }. Flags consume their own value. */
function parseArgs(argv) {
    const state = { input: null, out: null, mode: 'full', bytecode: false };
    for (let index = 0; index < argv.length; index += 1) {
        const arg = argv[index];
        if (arg === '-o') {
            state.out = argv[index + 1] ?? null;
            index += 1;
        } else if (arg === '--bytecode') {
            state.bytecode = true;
            state.input = argv[index + 1] ?? state.input;
            index += 1;
        } else if (arg === '--stats') {
            state.mode = 'stats';
        } else if (arg === '--constants') {
            state.mode = 'constants';
        } else if (!arg.startsWith('-') && state.input === null) {
            state.input = arg;
        }
    }
    return state;
}

/**
 * Per-function summary: prototype index, constant count and instruction count.
 * Enough to spot ballooned functions after a transform without reading 13k
 * lines of listing. Upvalue counts are not in this dump format (no `U<n>` rows
 * are emitted), so they are not reported here.
 */
function summarize(listing) {
    const blocks = listing.split(/^Function /m).slice(1);
    const rows = [['prototype', 'constants', 'instructions']];
    for (const block of blocks) {
        const head = /^(\d+)/.exec(block);
        const constants = (block.match(/^K\d+:/gm) || []).length;
        // Instruction lines are `<line>: [LABEL:] OPCODE ...`; constant rows are
        // `K<n>:` with no line number. A jump target carries a label between the
        // line number and the opcode (`74: L0: RETURN R0 0`), so it is optional.
        // Opcode names carry underscores (`FORGPREP_NEXT`), so the class allows them.
        const instructions = block
            .split('\n')
            .filter((line) => /^\d*:?\s*([A-Za-z]\w*:\s*)?[A-Z][A-Z0-9_]*\s/.test(line)).length;
        rows.push([String(head ? head[1] : '?'), String(constants), String(instructions)]);
    }
    const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
    return rows.map((row) => row.map((cell, column) => cell.padEnd(widths[column])).join('  ')).join('\n') + '\n';
}

const state = parseArgs(process.argv.slice(2));
if (!state.input) {
    usage();
} else {
    const lua = await Lua.create({ sandbox: false });
    const path = resolve(state.input);
    const source = state.bytecode ? null : readFileSync(path, 'utf8');
    const bytecode = state.bytecode ? new Uint8Array(readFileSync(path)) : lua.compile(source);

    // --stats needs the instruction stream to count it, so only --constants
    // can afford to drop it from the dump.
    const wantsCode = state.mode !== 'constants';
    const dumpOptions = {
        code: wantsCode,
        lines: wantsCode,
        locals: wantsCode,
        types: false,
        remarks: false,
        constants: true,
    };

    let listing = null;
    try {
        listing = state.bytecode
            ? typeof lua.dumpBytecode === 'function'
                ? lua.dumpBytecode(bytecode, dumpOptions)
                : null
            : lua.dump(source, dumpOptions);
    } catch (error) {
        console.error(`disasm: ${(error && error.message) || error}`);
        process.exitCode = 1;
    }

    if (listing === null) {
        // The wasm build only exposes dump() for source. A .luauc blob still has
        // a use through loadBytecode(): it validates the container and shows the
        // entry prototype without a recompile.
        try {
            lua.loadBytecode(bytecode);
            listing = `bytecode: ${bytecode.length} bytes, entry prototype loads clean\n`;
        } catch (error) {
            console.error(`disasm: not loadable as Luau bytecode: ${(error && error.message) || error}`);
            process.exitCode = 1;
        }
    }

    if (listing) {
        const header = state.bytecode
            ? `-- ${relative(HERE, path)} (bytecode, ${bytecode.length} bytes)\n`
            : `-- ${relative(HERE, path)} (source ${source.length} chars -> ${bytecode.length} bytecode bytes)\n`;
        const body = state.mode === 'stats' ? summarize(listing) : listing;
        if (state.out) {
            writeFileSync(resolve(state.out), header + body);
            console.error(`disasm: wrote ${state.out}`);
        } else {
            process.stdout.write(header + body);
        }
    }
    lua.dispose?.();
}
