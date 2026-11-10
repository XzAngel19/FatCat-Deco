// Minimal Luau runner for the test harness.
//
// Luau's loadstring takes (source, chunkname). Some harnesses pass a table as
// the second argument to emulate setfenv, so both shapes are accepted: a
// string is a chunk name and is ignored (the wasm compiler crashes on a
// non-string name), a table is applied with LuaFunction.setEnvironment before
// the chunk runs.
import { readFileSync } from 'node:fs';
import { Lua } from '@luau-rs/luau';

const path = process.argv[2];
if (!path) {
    console.error('usage: node run.mjs <file.luau>');
    process.exit(2);
}

const lua = await Lua.create({ sandbox: false });

const loadstring = lua.createFunction((...args) => {
    const source = args[0];
    const second = args[1];
    try {
        const fn = lua.load(String(source));
        // A table is an environment; anything else is a chunk name.
        if (second && typeof second === 'object' && typeof second.setEnvironment === 'function') {
            fn.setEnvironment(second);
        }
        return fn;
    } catch (error) {
        return null;
    }
});
lua.globals.set('loadstring', loadstring);

const setfenv = lua.createFunction((...args) => {
    const [fn, environment] = args;
    if (fn && environment && typeof fn.setEnvironment === 'function') {
        try {
            fn.setEnvironment(environment);
        } catch (error) {
            // A chunk without a writable environment keeps its own globals.
        }
    }
    return fn;
});
lua.globals.set('setfenv', setfenv);

lua.addEventListener('print', (event) => {
    console.log(event.text);
});

const source = readFileSync(path, 'utf8');
try {
    lua.execute(source);
} catch (error) {
    console.error('Error:', (error && (error.stack || error.traceback || error.message)) || error);
    process.exitCode = 1;
} finally {
    lua.dispose?.();
}
