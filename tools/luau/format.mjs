#!/usr/bin/env node
// StyLua for this repository, as a CLI over the wasm build.
//
//   node tools/luau/format.mjs --check            # exit 1 when a file is unformatted
//   node tools/luau/format.mjs --check Cobalt.txt
//   node tools/luau/format.mjs src/libraries       # rewrite files in place
//   node tools/luau/format.mjs --diff src/Wurst.lua
//
// The config lives in tools/luau/stylua.toml and is read here rather than by
// StyLua itself (the wasm entry point takes the settings as an object). Keep
// both honest: `--print-config` shows what this script actually applies.
import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as stylua from '@johnnymorganz/stylua';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const CONFIG_PATH = join(HERE, 'stylua.toml');

const ENUMS = {
    IndentType: { Tabs: stylua.IndentType.Tabs, Spaces: stylua.IndentType.Spaces },
    LineEndings: { Unix: stylua.LineEndings.Unix, Windows: stylua.LineEndings.Windows },
    QuoteStyle: {
        AutoPreferDouble: stylua.QuoteStyle.AutoPreferDouble,
        AutoPreferSingle: stylua.QuoteStyle.AutoPreferSingle,
        ForceDouble: stylua.QuoteStyle.ForceDouble,
        ForceSingle: stylua.QuoteStyle.ForceSingle,
    },
    CallParenType: {
        Always: stylua.CallParenType.Always,
        NoSingleString: stylua.CallParenType.NoSingleString,
        NoSingleTable: stylua.CallParenType.NoSingleTable,
        None: stylua.CallParenType.None,
        Input: stylua.CallParenType.Input,
    },
    CollapseSimpleStatement: {
        Never: stylua.CollapseSimpleStatement.Never,
        Input: stylua.CollapseSimpleStatement.Input,
        FunctionOnly: stylua.CollapseSimpleStatement.FunctionOnly,
    },
};

/** Minimal TOML reader: `key = value` lines, strings, numbers, booleans. */
export function readStyluaConfig(path = CONFIG_PATH) {
    const raw = readFileSync(path, 'utf8');
    const values = {};
    for (const line of raw.split('\n')) {
        const trimmed = line.trim();
        if (trimmed === '' || trimmed.startsWith('#')) continue;
        const match = /^([A-Za-z_]\w*)\s*=\s*(.+)$/.exec(trimmed);
        if (!match) continue;
        const [, key, rawValue] = match;
        let value = rawValue.replace(/\s+#.*$/, '');
        if (/^".*"$/.test(value)) values[key] = value.slice(1, -1);
        else if (/^'.*'$/.test(value)) values[key] = value.slice(1, -1);
        else if (/^(true|false)$/.test(value)) values[key] = value === 'true';
        else if (/^-?\d+$/.test(value)) values[key] = Number(value);
        else values[key] = value;
    }
    return values;
}

// TOML key -> which enum group its string value belongs to.
const CONFIG_ENUMS = {
    indent_type: 'IndentType',
    line_endings: 'LineEndings',
    quote_style: 'QuoteStyle',
    call_parentheses: 'CallParenType',
    collapse_simple_statement: 'CollapseSimpleStatement',
};

export function buildConfig(values = readStyluaConfig()) {
    if (!(values instanceof Map)) values = new Map(Object.entries(values));
    const config = stylua.Config.new();
    for (const [key, value] of values) {
        const group = CONFIG_ENUMS[key];
        if (group) {
            const resolved = ENUMS[group][value];
            if (resolved === undefined) {
                throw new Error(`stylua.toml: ${key} = "${value}" is not one of ${Object.keys(ENUMS[group]).join('|')}`);
            }
            config[key] = resolved;
        } else if (key !== 'syntax' && key in config) {
            config[key] = value;
        }
    }
    return config;
}

/**
 * Format one source string.
 *
 * StyLua reports "null pointer passed to rust" when the wasm instance has
 * already been disposed, so the config is rebuilt per call and a failure is
 * re-raised with the file name attached by the caller.
 */
export function formatSource(source, config = buildConfig()) {
    return stylua.formatCode(source, config, null, stylua.OutputVerification.None);
}

/** `formatSource`, but per-call config: safe for long file lists. */
export function formatFile(file) {
    const source = readFileSync(file, 'utf8');
    const formatted = stylua.formatCode(source, buildConfig(), null, stylua.OutputVerification.None);
    return { source, formatted };
}

function targets(patterns) {
    if (patterns.length === 0) {
        // Default scope: the decompiler sources. Cobalt.txt is a 467 KB bundle
        // that predates StyLua, so formatting it is opt-in by path.
        const scopes = ['src', 'tools'].filter((dir) => existsSync(resolve(ROOT, dir)));
        const found = [];
        for (const scope of scopes) {
            const out = execFileSync('find', [scope, '-name', '*.lua', '-o', '-name', '*.luau'], { cwd: ROOT })
                .toString()
                .trim();
            found.push(...out.split('\n').filter(Boolean));
        }
        // Definitions (`declare ...`) are not scripts: StyLua rejects them with
        // "memory access out of bounds". Unpacked vendor tooling is not ours.
        const skipped = [/\/node_modules\//, /\/vendor\//, /\/definitions\//, /\/bin\//];
        return found
            .filter((file) => !skipped.some((pattern) => pattern.test(file)))
            .sort()
            .map((p) => resolve(ROOT, p));
    }
    const files = [];
    for (const pattern of patterns) {
        const absolute = resolve(pattern);
        if (statSync(absolute).isDirectory()) {
            const found = execFileSync('find', [absolute, '-name', '*.lua']).toString().trim().split('\n');
            files.push(...found.filter(Boolean).sort());
        } else {
            files.push(absolute);
        }
    }
    return files;
}

/** @returns {{file: string, formatted: boolean}[]} */
export function checkFiles(files) {
    return files.map((file) => {
        try {
            const { source, formatted } = formatFile(file);
            return { file, formatted: formatted === source };
        } catch (error) {
            return { file, formatted: true, error: String((error && error.message) || error) };
        }
    });
}

function firstDifference(expected, actual) {
    const want = expected.split('\n');
    const have = actual.split('\n');
    for (let index = 0; index < Math.max(want.length, have.length); index += 1) {
        if (want[index] !== have[index]) {
            return { line: index + 1, want: want[index], have: have[index] };
        }
    }
    return null;
}

function main() {
    const argv = process.argv.slice(2);
    const mode = argv.includes('--check') ? 'check' : argv.includes('--diff') ? 'diff' : 'write';
    const files = targets(argv.filter((a) => !a.startsWith('-')));
    if (files.length === 0) {
        console.error('format: no files matched');
        process.exitCode = 2;
        return;
    }
    if (mode === 'write') {
        let changed = 0;
        for (const file of files) {
            const { source, formatted } = formatFile(file);
            if (formatted !== source) {
                writeFileSync(file, formatted);
                changed += 1;
                console.log(`formatted ${relative(ROOT, file)}`);
            }
        }
        console.error(`format: ${files.length} file(s), ${changed} rewritten`);
        return;
    }

    const results = checkFiles(files);
    const dirty = results.filter((result) => !result.formatted);
    if (mode === 'diff') {
        for (const { file } of dirty) {
            const { source, formatted } = formatFile(file);
            const spot = firstDifference(formatted, source);
            console.log(`--- ${relative(ROOT, file)}`);
            if (spot) {
                console.log(`    line ${spot.line}`);
                console.log(`  - ${spot.want.replace(/\t/g, '→   ')}`);
                console.log(`  + ${spot.have.replace(/\t/g, '→   ')}`);
            }
        }
    }
    for (const { file, error } of results) {
        if (error) console.log(`unreadable: ${relative(ROOT, file)} (${error})`);
    }
    for (const { file } of dirty) console.log(`unformatted: ${relative(ROOT, file)}`);
    console.error(`format: ${files.length} file(s) checked, ${dirty.length} unformatted`);
    const unreadable = results.filter((result) => result.error);
    if (unreadable.length > 0) {
        console.error(`format: ${unreadable.length} file(s) StyLua could not parse`);
    }
    process.exitCode = dirty.length === 0 ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main();
}
