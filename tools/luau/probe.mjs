#!/usr/bin/env node
// Load a definitions file with the real Luau analyzer.
//
//   node tools/luau/probe.mjs tools/luau/definitions/core.d.luau
//
// Prints `{"ok":true}` when the analyzer accepts the definitions, otherwise
// prints the error plus `{"ok":false}`. Used by build_definitions.py to close
// over the types the analyzer still reports as unknown.
import { readFileSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { Analysis } from '@luau-rs/luau/analysis';

const paths = process.argv.slice(2);
if (paths.length === 0) {
    console.error('usage: node tools/luau/probe.mjs <definitions.d.luau...>');
    process.exit(2);
}

const definitions = paths.map((path) => {
    const absolute = resolve(path);
    return { name: relative(process.cwd(), absolute), source: readFileSync(absolute, 'utf8') };
});
try {
    const analysis = await Analysis.create({ mode: 'nonstrict', lint: false, definitions });
    analysis[Symbol.dispose]?.();
    console.log('{"ok":true}');
} catch (error) {
    console.log(String((error && error.message) || error));
    console.log('{"ok":false}');
    process.exitCode = 1;
}
