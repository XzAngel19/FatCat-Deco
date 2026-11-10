# Luau toolchain — qué se instaló y por qué (Fat Cat Decompiler)

Todo está **dentro del repo**: un clon nuevo, un sandbox con `node_modules`
borrado o un CI sin red se reconstruyen con un comando.

```bash
bash tools/luau/setup.sh --verify   # descompacta + prueba cada herramienta
bash tools/validate.sh              # la puerta completa (24 + 9 checks)
```

Probado en este árbol el 2026-11-10: `PASS 28 toolchain checks`,
`PASS 610 prototypes`, `analyze: 0 new · 4 error(s) · 125 warning(s)`,
`minify: Cobalt.txt 467 KB -> 313 KB (−33.0 %)`.

## Lo que no se pudo traer, y por qué

El entorno solo permite salida a `github.com`, `api.github.com`,
`codeload.github.com`, `registry.npmjs.org`, `pypi.org` y
`files.pythonhosted.org`. Los binarios nativos de las releases de GitHub
(`luau`, `luau-compile`, `luau-analyze`, `darklua`, `stylua`, `selene`) se
descargan desde `objects.githubusercontent.com`
(`release-assets.githubusercontent.com`), que está **bloqueado**:

```
curl -L https://github.com/luau-lang/luau/releases/download/0.739/luau-ubuntu.zip
curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL
```

`api.github.com` sí responde, así que las versiones y los assets se pueden
enumerar. La solución no fue un binario nativo sino la **build wasm de cada
herramienta**, publicada en npm y vendorizada como tarball:

| Necesidad | Herramienta | Script | Tarball |
| --- | --- | --- | --- |
| ejecutar Luau (harnesses) | `@luau-rs/luau` 0.739 | `tools/luau/bin/luau` | `luau-rs-luau-0.739.0.tgz` (2.7 MB) |
| compilar / comprobar sintaxis | el mismo front end | `bin/luau-compile` | — |
| type check + lints | el mismo front end | `bin/luau-analyze` | — |
| **DarkLua** 0.19 | `darklua-wasm` 0.1.0 | `bin/luau-minify` | `darklua-wasm-0.1.0.tgz` (1.2 MB) |
| **StyLua** 2.6 | `@johnnymorganz/stylua` 2.6.0 | `bin/luau-format` | `johnnymorganz-stylua-2.6.0.tgz` (912 KB) |
| **desensamblador** | escrito encima del front end | `bin/luau-disasm` | — |
| **validador de bytecode** | escrito encima del front end | `bin/luau-validate` | — |
| dependencia de `@luau-rs/luau` | `valibot` 1.5.0 | — | `valibot-1.5.0.tgz` (188 KB) |

`tools/luau/setup.sh` desempaqueta los cuatro tarballs en `node_modules/` y crea
los siete binarios en `tools/luau/bin/`. Es idempotente y no toca la red.
`node_modules/` y `bin/` están en `.gitignore`: los tarballs son la fuente de
verdad.

`selene` (linter) y `luau-lsp` (language server) **no** se instalaron: sus
paquetes npm son wrappers que descargan el binario de una release al ejecutarse,
y esa descarga está bloqueada. `luau-analyze` cubre el mismo trabajo en CI; para
editor, el LSP nativo funciona en la máquina del usuario.

## Las dos piezas nuevas: desensamblador y validador

Un decompiler se lee desde el **bytecode**, no desde el fuente.
`luau-compile` solo contesta «¿parsea?». Las dos herramientas nuevas imprimen y
comprueban lo que el decompiler realmente consume:

```bash
bin/luau-disasm Cobalt.txt                # 610 prototipos, opcodes, constantes
bin/luau-disasm Cobalt.txt --stats        # resumen por prototipo
bin/luau-disasm Cobalt.txt --constants    # solo el pool de constantes
bin/luau-disasm --bytecode dump.luauc     # un blob ya extraído por el executor

bin/luau-validate Cobalt.txt              # header LBC + loadBytecode
bin/luau-validate --emit out.luauc Cobalt.txt
```

Qué prueba `luau-validate`, por archivo:

1. el fuente compila;
2. el contenedor empieza con el byte de versión LBC (`100` = versión 0 + tipo
   `userdata`, lo que emite este front end);
3. la tabla de strings del header se puede leer entera (1 713 entradas en
   `Cobalt.txt`) — un contenedor truncado falla aquí;
4. `loadBytecode` acepta el chunk.

Esto es el sustituto local de `luau-validate` de Roblox. Sirve para validar lo
que el decompiler produce **y** lo que el executor entrega con
`getscriptbytecode`.

## El detalle que costó el run: definiciones de tipos

`luau-analyze` sin definiciones reporta **9 129 diagnósticos**, casi todos
`Unknown global 'CFrame'` / `Unknown type 'Vector3'`. La fuente correcta es
`globalTypes.d.luau` de luau-lsp (880 KB, 2 306 declaraciones, generado del API
dump de Roblox). Se baja así, sin releases bloqueadas:

```bash
curl -sS "https://api.github.com/repos/JohnnyMorganz/luau-lsp/contents/scripts/globalTypes.d.luau?ref=main" \
  | python3 -c "import json,sys,base64;open('/tmp/globalTypes.d.luau','wb').write(base64.b64decode(json.load(sys.stdin)['content']))"
```

Cargarlo entero **no funciona**: `Code is too complex to typecheck!`.
`definitions/build_definitions.py` construye un subconjunto y lo **cierra sobre
sí mismo**: lo renderiza, lo carga con el analizador real (`probe.mjs`), lee los
`Unknown type` que faltan, los añade, y repite hasta que carga limpio.

En este árbol el fichero generado se llama `definitions/roblox-api.d.luau`
(antes `core.d.luau`) porque el repo no es un menú con su propio `core`: hay
**un** API dump y las globals del executor viven aparte, en
`definitions/runtime.d.luau`.

### Ajustes hechos para `Cobalt.txt`

| Cambio | Efecto |
| --- | --- |
| `runtime.d.luau` reescrito como superficie de executor (135 globals) | 170 → 13 errores |
| `UnreliableRemoteEvent`, `BindableEvent`, `BindableFunction` añadidos al dump | 13 → 4 errores |
| `analyze-baseline.json` con los 4 restantes | la puerta falla solo con errores **nuevos** |

Los 4 errores aceptados, todos limitaciones del front end wasm, no del código:

- `obj:IsA("MeshPart")` **no estrecha el tipo**: el analizador sigue viendo
  `Instance`, y `string.format("%s", Vector3)` acaba comparando contra un
  `Instance`.
- `local k: Enum.KeyCode` no resuelve: `Enum` es la tabla global, no un espacio
  de nombres de tipos. `Enum.KeyCode.A` (expresión) sí funciona.
- `CodeGen.CallInfo` es un tipo que Cobalt exporta desde su propio árbol de
  `export type`; el analizador no lo resuelve a través del bundle plano.

`--baseline` falla **solo con errores nuevos**, y la suite demuestra que un
global inventado la rompe (`totallyNotAGlobal` → `NEW`).

## DarkLua: dos recetas

`tools/luau/minify.mjs`, la receta de release (13 reglas, semántica intacta):

```
remove_types → remove_debug_profiling → remove_compound_assignment →
convert_local_function_to_assign → group_local_assignment → remove_empty_do →
remove_unused_if_branch → remove_unused_while → remove_unused_variable →
remove_method_definition → rename_variables → remove_comments → remove_spaces
```

`Cobalt.txt` 467 KB → **313 KB (−33.0 %)**, y el resultado compila y valida.

Y una receta pesada, opt-in, para la **salida del decompiler** (18 reglas, en
`darklua.heavy.json`): añade `remove_assertions`, `remove_nil_declaration`,
`convert_index_to_field`, `remove_function_call_parens` y
`compute_expression`. 467 KB → 303 KB (−33.8 %).

```bash
node tools/luau/minify.mjs Cobalt.txt --config tools/luau/darklua.heavy.json -o build/Cobalt.heavy.lua
```

Ninguna de las dos reescribe `require()`: `Cobalt.txt` ya es un bundle
autocontenido, y `convert_require` rompería los `require(script.X)` que el
decompiler muestra al usuario.

## Puertas en `tools/validate.sh`

```
luau-compile        todos los .lua/.luau (menos los .d.luau) compilan
Cobalt.txt          compila, valida su bytecode y desensambla 610 prototipos
luau-analyze        --baseline: 0 errores fuera de la deuda aceptada
DarkLua release     minifica y el resultado vuelve a validar
test_luau_toolchain 28 suites del propio toolchain
```

Sobre el formato, una advertencia aprendida a golpes: **no se reformatea el
árbol entero**. StyLua cambia `{[string]: any}` por `{ [string]: any }`, y hay
suites que comparan ese texto literal. La puerta es por fichero tocado:

```bash
node tools/luau/format.mjs --check Cobalt.txt
node tools/luau/format.mjs Cobalt.txt      # reescribe en sitio
```

`Cobalt.txt` está **sin formatear** (467 KB escritos a mano, CRLF, tabs): el
`--check` lo reporta y eso es lo esperado hasta que se decida un reformateo en un
commit propio.

## Los dos fallos reales que encontró el toolchain

1. `minify.mjs` no aceptaba `-o` sin `--config`: `indexOf()` devuelve `-1`, y
   `-1 + 1` metía el índice `0` en el set de «argumentos ya consumidos» y se
   comía la ruta de entrada. El test lo cazó porque la receta de release dejó de
   ejecutarse en cuanto se añadió `--config`.
2. `disasm.mjs --stats` contaba cero instrucciones: `dump()` solo emite el
   stream de código si se pide `code: true`, y las etiquetas de salto
   (`74: L0: RETURN R0 0`) y los nombres con guion bajo (`FORGPREP_NEXT`) no
   entraban en el patrón. Ahora el total del resumen cuadra exactamente con las
   líneas del listado (26 761) y el test lo compara.
