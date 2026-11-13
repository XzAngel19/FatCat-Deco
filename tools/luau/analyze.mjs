#!/usr/bin/env node
// Static analysis for the Fat Cat Decompiler sources: Luau type checking + lints.
//
//   node tools/luau/analyze.mjs                        # default target: Cobalt.txt
//   node tools/luau/analyze.mjs path/to/file.luau       # specific files
//   node tools/luau/analyze.mjs --mode=strict           # nonstrict (default)|strict|nocheck
//   node tools/luau/analyze.mjs --errors                # only errors (default: errors+warnings)
//   node tools/luau/analyze.mjs --json                  # machine readable
//   node tools/luau/analyze.mjs --baseline              # only errors not in the baseline
//   node tools/luau/analyze.mjs --write-baseline        # record the current errors
//
// Exit code 1 when an error is reported, 0 otherwise. Warnings never fail.
//
// The analyzer is the same Luau front end the game runs (luau-analyze through
// wasm), fed with the Roblox API subset (definitions/roblox-api.d.luau) and the
// executor surface (definitions/runtime.d.luau).
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Analysis } from '@luau-rs/luau/analysis';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const BASELINE = join(HERE, 'analyze-baseline.json');
const DEFAULT_TARGETS = ['Cobalt.txt'];

export const DEFINITIONS = [
    join(HERE, 'definitions', 'roblox-api.d.luau'),
    join(HERE, 'definitions', 'runtime.d.luau'),
];

const BASELINE_COMMENT =
    'Known analyzer reports for Cobalt.txt: Luau cannot narrow through IsA(), Enum.* is not a type in the wasm front end, and Cobalt type-checks its own CodeGen.CallInfo against an untyped export root. See docs/LUAU-TOOLCHAIN.md.';

export function loadBaseline(path = BASELINE) {
    if (!existsSync(path)) return [];
    const data = JSON.parse(readFileSync(path, 'utf8'));
    return Array.isArray(data.entries) ? data.entries : [];
}

/**
 * Expand the target list into files.
 *
 * A directory is walked for `.lua`/`.luau` files instead of being handed to
 * `readFileSync`, which fails with EISDIR. That matters here because the
 * project modules live in five folders with `&` and spaces in their names: a
 * shell glob for them is painful to write correctly, `analyze src/project` is
 * not.
 */
export function sourceFiles(patterns) {
    if (patterns.length > 0) {
        const files = [];
        for (const pattern of patterns) {
            const path = resolve(pattern);
            if (existsSync(path) && statSync(path).isDirectory()) {
                const found = readdirSync(path, { recursive: true })
                    .filter((entry) => /\.luau?$/.test(entry))
                    .map((entry) => resolve(path, entry))
                    .sort();
                files.push(...found);
            } else {
                files.push(path);
            }
        }
        return files;
    }
    return DEFAULT_TARGETS.filter((target) => existsSync(resolve(ROOT, target))).map((target) =>
        resolve(ROOT, target),
    );
}

/** Build an `Analysis` loaded with the Roblox + executor definitions. */
export async function createAnalysis({ mode = 'nonstrict', lint = true } = {}) {
    const definitions = DEFINITIONS.filter((path) => existsSync(path)).map((path) => ({
        name: relative(ROOT, path),
        source: readFileSync(path, 'utf8'),
    }));
    return Analysis.create({ mode, lint, definitions });
}

/** Run the analyzer over the given files and flatten its diagnostics. */
export function diagnosticsFor(analysis, files) {
    for (const file of files) {
        analysis.setModule(file, readFileSync(file, 'utf8'), 'module');
    }
    const results = [];
    for (const file of files) {
        for (const diagnostic of analysis.check(file).diagnostics) {
            const single = diagnostic.message.replace(/\s*\n\s*/g, ' ');
            results.push({
                module: diagnostic.module,
                file: relative(ROOT, diagnostic.module),
                line: diagnostic.location.begin.line + 1,
                column: diagnostic.location.begin.column + 1,
                severity: diagnostic.severity,
                code: diagnostic.code,
                message: single,
            });
        }
    }
    return results.sort((a, b) =>
        a.file === b.file ? a.line - b.line || a.column - b.column : a.file.localeCompare(b.file),
    );
}

/** Stable identity for a diagnostic: file, code and message (lines drift). */
function key(entry) {
    return `${entry.file}|${entry.code}|${entry.message}`;
}

function main() {
    const argv = process.argv.slice(2);
    const flags = argv.filter((arg) => arg.startsWith('-'));
    const targets = argv.filter((arg) => !arg.startsWith('-'));
    const mode = (flags.find((flag) => flag.startsWith('--mode=')) || '--mode=nonstrict').split('=')[1];
    const errorsOnly = flags.includes('--errors');
    const asJson = flags.includes('--json');
    const useBaseline = flags.includes('--baseline');
    const writeBaseline = flags.includes('--write-baseline');

    const files = sourceFiles(targets);
    if (files.length === 0) {
        console.error('analyze: no targets found');
        process.exitCode = 2;
        return;
    }

    return (async () => {
        const analysis = await createAnalysis({ mode });
        const all = diagnosticsFor(analysis, files);
        analysis[Symbol.dispose]?.();

        const errors = all.filter((entry) => entry.severity === 'error');
        const shown = errorsOnly ? errors : all;

        let emitted = shown;
        if (useBaseline) {
            // The baseline only ever records errors; warnings always pass.
            const known = new Set(loadBaseline());
            emitted = errors.filter((entry) => !known.has(key(entry)));
        }
        if (writeBaseline) {
            const entries = [...new Set(errors.map((entry) => key(entry)))].sort();
            writeFileSync(
                BASELINE,
                JSON.stringify({ comment: BASELINE_COMMENT, entries }, null, 2) + '\n',
            );
            console.error(`analyze: wrote ${entries.length} baseline entr(ies) to ${relative(ROOT, BASELINE)}`);
        }

        if (asJson) {
            process.stdout.write(JSON.stringify(emitted, null, 2) + '\n');
        } else {
            for (const entry of emitted) {
                const prefix = useBaseline ? 'NEW ' : '';
                console.log(`${prefix}${entry.file}:${entry.line}:${entry.column}: ${entry.severity}: ${entry.message} (${entry.code})`);
            }
            console.error(
                `analyze: ${files.length} file(s) · ${emitted.length} ${useBaseline ? 'new ' : ''}shown · ` +
                    `${errors.length} error(s) · ${all.length - errors.length} warning(s) · mode=${mode}`,
            );
        }
        process.exitCode = (useBaseline ? emitted.length : errors.length) > 0 ? 1 : 0;
    })();
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main();
}
