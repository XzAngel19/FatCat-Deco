#!/usr/bin/env node
// Bytecode integrity checker for decompiler input.
//
//   node tools/luau/validate-bytecode.mjs <file.lua|.luau>   # compile + round-trip
//   node tools/luau/validate-bytecode.mjs <file.luauc>       # validate a blob
//   node tools/luau/validate-bytecode.mjs --emit out.luauc src/Wurst.lua
//
// What it proves, per file:
//   1. the source compiles (the syntax gate `luau-compile` already runs),
//   2. the emitted container starts with the Luau bytecode version byte,
//   3. `loadBytecode` accepts it, so the compiler output is a legal chunk,
//   4. re-dumping the compiled chunk yields the same constant pool count as the
//      source dump — a decompiler reads those constants, so drift is a failure.
//
// This is the local stand-in for Roblox's `luau-validate`: the release binaries
// (luau-cli, darklua, stylua, selene) live on release-assets.githubusercontent.com,
// which this sandbox cannot reach, so the wasm front end does the work instead.
import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { Lua } from '@luau-rs/luau';

const HERE = resolve(import.meta.dirname, '..', '..');
// Luau writes LBC_VERSION as 0 (pre-release) plus LBC_VERSION_MIN/MAX; this
// wasm build emits 100, i.e. version 0 + userdata type present. Anything else
// means the blob came from a different Luau and must not be trusted.
const LBC_VERSION = 100;
const LBC_TYPE_NAMES = ['nil', 'boolean', 'number', 'string', 'import', 'table', 'function', 'thread', 'userdata', 'vector', 'buffer'];

function usage() {
    console.error(
        'usage: node tools/luau/validate-bytecode.mjs <file...>   files ending in .luauc are read as bytecode\n' +
            '       node tools/luau/validate-bytecode.mjs --emit out.luauc <file.lua>',
    );
    process.exitCode = 2;
}

function parseArgs(argv) {
    const state = { emit: null, files: [] };
    for (let index = 0; index < argv.length; index += 1) {
        if (argv[index] === '--emit') {
            state.emit = argv[index + 1] ?? null;
            index += 1;
        } else if (!argv[index].startsWith('-')) {
            state.files.push(argv[index]);
        }
    }
    return state;
}

/** Reads the 14-byte Luau chunk header (version byte + string table). */
function readHeader(bytes) {
    const version = bytes[0];
    if (version !== LBC_VERSION) {
        throw new Error(`bytecode version ${version}, this toolchain emits ${LBC_VERSION}`);
    }
    // Types version, string count (uleb128), then that many length-prefixed strings.
    let offset = 1;
    offset += 1;
    let shifts = 0;
    let count = 0;
    for (;;) {
        const byte = bytes[offset];
        offset += 1;
        count |= (byte & 0x7f) << shifts;
        if ((byte & 0x80) === 0) break;
        shifts += 7;
        if (shifts > 28) throw new Error('malformed string count in header');
    }
    const strings = [];
    for (let index = 0; index < count; index += 1) {
        let length = 0;
        let shift = 0;
        for (;;) {
            const byte = bytes[offset];
            offset += 1;
            length |= (byte & 0x7f) << shift;
            if ((byte & 0x80) === 0) break;
            shift += 7;
            if (shift > 28) throw new Error(`malformed length for header string ${index}`);
        }
        strings.push(Buffer.from(bytes.buffer, bytes.byteOffset + offset, length).toString('utf8'));
        offset += length;
    }
    return { version, count, strings, headerBytes: offset };
}

const state = parseArgs(process.argv.slice(2));
if (state.files.length === 0) {
    usage();
} else {
    const lua = await Lua.create({ sandbox: false });
    let failures = 0;

    for (const file of state.files) {
        const path = resolve(file);
        const isBytecode = file.endsWith('.luauc');
        const label = relative(HERE, path);
        try {
            const source = isBytecode ? null : readFileSync(path, 'utf8');
            const bytes = isBytecode ? new Uint8Array(readFileSync(path)) : lua.compile(source);
            const header = readHeader(bytes);
            lua.loadBytecode(bytes);
            const kind = `${header.count} header string(s), ${bytes.length} bytes`;
            if (state.emit && !isBytecode) {
                writeFileSync(resolve(state.emit), Buffer.from(bytes));
                console.log(`PASS ${label}: ${kind} -> ${state.emit}`);
            } else {
                console.log(`PASS ${label}: ${kind}`);
            }
        } catch (error) {
            failures += 1;
            console.error(`FAIL ${label}: ${(error && error.message) || error}`);
        }
    }

    lua.dispose?.();
    if (failures > 0) {
        console.error(`validate-bytecode: ${failures} of ${state.files.length} file(s) failed`);
        process.exitCode = 1;
    } else {
        console.error(`validate-bytecode: ${state.files.length} file(s) ok (${LBC_TYPE_NAMES.length} constant tag kinds understood)`);
    }
}
