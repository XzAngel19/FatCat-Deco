#!/usr/bin/env node
// Syntax checker: compiles every .lua source with the wasm Luau compiler.
// No chunk name is passed: the compiler crashes on a non-string name.
import { readFileSync } from 'node:fs';
import { Lua } from '@luau-rs/luau';

const files = process.argv.slice(2);
if (files.length === 0) {
    console.error('usage: luau-compile <file...>');
    process.exit(2);
}

const lua = await Lua.create({ sandbox: false });
let failed = 0;
for (const file of files) {
    const source = readFileSync(file, 'utf8');
    try {
        lua.compile(source);
    } catch (error) {
        failed += 1;
        console.error(`${file}: ${(error && (error.message || error)) || error}`);
    }
}
lua.dispose?.();
process.exit(failed === 0 ? 0 : 1);
