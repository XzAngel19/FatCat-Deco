# FatCat-Deco — Fat Cat Decompiler

Herramientas y banco de trabajo para leer, validar y volver a emitir código
Luau de Roblox (`Cobalt.txt`, un bundle runtime de 467 KB).

## Arranque

```bash
bash tools/luau/setup.sh --verify   # toolchain Luau desde los tarballs vendorizados
bash tools/validate.sh              # puerta completa
bash tools/validate.sh --quick      # sin el type checker
```

Solo necesita `node` (probado en v22) y `python3` para la suite. No hay
`npm install` ni descargas: todo está vendorizado en `tools/luau/vendor/`.

## Herramientas

| Comando | Qué hace |
| --- | --- |
| `bin/luau <file>` | ejecuta Luau (harnesses) |
| `bin/luau-compile <file…>` | comprueba sintaxis |
| `bin/luau-analyze <file…>` | type check + lints contra el API de Roblox y el executor |
| `bin/luau-format <file…>` | StyLua (formatea en sitio, `--check` para la puerta) |
| `bin/luau-minify <file> -o out` | DarkLua, receta de release |
| `bin/luau-disasm <file>` | prototipos, opcodes y constantes del bytecode |
| `bin/luau-validate <file>` | integridad del contenedor `.luauc` |

Los binarios viven en `tools/luau/bin/`; `bash tools/luau/setup.sh` los recrea.

```bash
tools/luau/bin/luau-disasm Cobalt.txt --stats     # 610 prototipos, 26 761 instrucciones
tools/luau/bin/luau-validate Cobalt.txt           # 1 713 strings de header, 398 976 bytes
node tools/luau/analyze.mjs --baseline            # 0 errores nuevos
node tools/luau/minify.mjs Cobalt.txt -o build/Cobalt.min.lua
```

## Documentación

- [`docs/LUAU-TOOLCHAIN.md`](docs/LUAU-TOOLCHAIN.md) — qué se instaló, qué no se
  pudo traer y por qué, y los fallos que encontró el propio toolchain.
- `AGENTS.md` — guía de trabajo del repositorio.
